{-# LANGUAGE ExistentialQuantification, RankNTypes, RecordWildCards, DeriveDataTypeable #-}
module Manager.Manage where

import Manager.Types

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM

import Control.Exception

import Control.Monad
import Control.Monad.Trans.Reader

import Data.Typeable

data CullCrash = CullCrash deriving (Eq, Show, Typeable)
instance Exception CullCrash

-- |manage starts a manager process with an empty list of
-- submanagers, and launches a culling thread, which removes
-- completed submanagers from the tracking list.
manage :: Manager () -> Environment -> IO ()
manage m env = do
  subs <- newTVarIO $ Just []
  tid <- myThreadId
  
  mask $ \restore -> do
    culler <- async $ cullLoop restore tid subs
    r <- try (restore (runReaderT (runReaderT m env) $ (ManageCtl subs)))
    case r of
      -- If our manager has crashed with some exception, then we pass the
      -- exception to a handler to do the cleanup.
      Left e -> handleException e subs culler
      -- Otherwise, our manager ran successfuly, and there is nothing left
      -- to do, so cleanup any remaining child (submanager) threads.
      Right _ -> do
        cancel culler
        killSubManagers subs
        waitCatch culler
        return ()

  where
    
    cullLoop :: (forall a. IO a -> IO a) ->
                ThreadId ->
                SubManagerLog ->
                IO ()
    cullLoop restore parentID subs = let tk = ThreadKilled in
      restore (forever $ cull subs) `catch`
        (\e -> if e == tk then throwIO e else do
            throwTo parentID CullCrash
            throwIO e)


    -- handleException has the task of cleaning up. There are two cases:
    -- 1) either our culling thread crashed and sent us an exception, in
    --    which case cullProc is already dealing with an exception and we
    --    just need to wait for it to do its cleanup.
    -- 2) something went wrong in the manager itself, and cullProc doesn't
    --    know about this, so we need to cancel the cullProc thread manually,
    --    and wait for it to do cleanup.
    -- We deal with these two cases separately. In both cases, the submanagers
    -- need cleaning up.
    handleException :: SomeException ->
                       SubManagerLog ->
                       Async () ->
                       IO ()
    handleException e subs culler = do 
      killSubManagers subs
      let ex = fromException e :: Maybe CullCrash
      case ex of
        Just _ -> {- The exception was a CullCrash -} waitCatch culler >> return ()
        Nothing -> cancel culler >> waitCatch culler >> return ()
      throwIO e
    
    killSubManagers :: SubManagerLog -> IO ()
    killSubManagers sml = do
      submanagers <- getKillList sml
      sequence $ map kill submanagers
      sequence $ map (waitCatch.process) submanagers
      return ()
      
    getKillList :: SubManagerLog -> IO [SubManager]
    getKillList sml = atomically $ do
      subs <- swapTVar sml Nothing
      case subs of
        Just targets -> return targets
        Nothing -> {- Already killed -} return []

    kill :: SubManager -> IO ()
    kill SubManager{..} = cancel process

-- |cull takes our tracked SubManagers, and returns a list of
-- completed submanagers, leaving behind only those that are
-- still running.
cull :: SubManagerLog -> IO [SubManager]
cull sml = atomically $ do
    subs <- readTVar sml
    maybe (return []) tidy subs
    where
      tidy :: [SubManager] -> STM [SubManager]
      tidy submanagers = do
        (done,working) <- divideSubmanagers submanagers
        writeTVar sml (Just working)
        return done


-- |divideSubmanagers takes a list of SubManagers and returns two lists:
-- one a list of completed submanagers, and the other a list of those
-- still running. Ordering of lists is not guaranteed to be preserved.
-- Will block if nothing has finished running
divideSubmanagers :: [SubManager] -> STM ([SubManager],[SubManager])
divideSubmanagers submanagers = go [] [] submanagers
  where
    -- This is really a right fold, but expressing it that way is
    -- opaque. This recursive worker function works along the list
    -- of submanagers and divides them into culls and retries.
    go [] _ [] = retry
    go cs rs [] = return (cs,rs)
    go cs rs (s:ss) = (tryDecide s cs rs ss) `orElse` go cs (s:rs) ss

    -- tryDecide looks to see if the submanager s has finished,
    -- otherwise it does an STM retry. Note that waitCatchSTM contains
    -- a retry. If the submanager has finished, it is added to the
    -- cull list.
    tryDecide s cs rs ss = do
      _ <- waitCatchSTM (process s)
      go (s:cs) rs ss