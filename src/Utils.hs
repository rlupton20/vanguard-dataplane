module Utils
( readM ) where

import Text.Read

readM :: (Read a, Monad m) => String -> m a
readM str = do
  let d = readMaybe str
  case d of
    Nothing -> fail $ "Could not read string: " ++ str
    Just parse -> return parse