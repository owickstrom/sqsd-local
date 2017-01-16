{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Main where

import           Control.Lens
import           Data.Text                (Text)
import qualified Data.Text                as Text
import           Network.SQS.Daemon.Local
import           System.Console.GetOpt
import           System.Environment
import           System.IO

data Options
  = Options { _daemonOptions :: DaemonOptions
            , _showHelp      :: Bool
            , _showVersion   :: Bool
            } deriving (Show, Eq, Ord)

makeLenses ''Options

defaultOptions :: Text -> Options
defaultOptions workerQueueName' =
  Options { _daemonOptions = DaemonOptions { _workerUrl = "http://localhost:5000"
                                           , _workerQueueName = workerQueueName'
                                           , _deadLetterQueueName = Nothing
                                           , _httpTimeout = Just 30
                                           }
          , _showHelp = False
          , _showVersion = False
          }

readMaybe :: Read a => String -> Maybe a
readMaybe s =
  case reads s of
    [(val, "")] -> Just val
    _           -> Nothing

options :: [OptDescr (Options -> Options)]
options =
  [ Option ['h'] ["help"]
    (NoArg (set showHelp True))
    "Print this help message"
  , Option ['V'] ["version"]
    (NoArg (set showVersion True))
    "Print the CLI version"
  , Option "u" ["worker-url"]
    (ReqArg (set (daemonOptions . workerUrl) . Text.pack) "URL")
    "Specify the worker URL to send POST requests to"
  , Option "d" ["dead-letter-queue-name"]
    (ReqArg (set (daemonOptions . deadLetterQueueName) . Just . Text.pack) "NAME")
    "Name of the SQS queue to send messages to which the worker failed processing"
  , Option "d" ["http-timeout"]
    (ReqArg (set (daemonOptions . httpTimeout) . readMaybe) "NAME")
    "Timeout for the HTTP POST request to worker"
  ]

usage :: String
usage = "Usage: sqsd-local WORKER_QUEUE_NAME [options]"

help :: String
help = usageInfo (usage ++ "\n\n" ++ "Options:\n") options

parseOptions :: [String] -> IO (Either String Options)
parseOptions argv =
  case getOpt Permute options argv of
    (o, [queueName], []) ->
      return (Right (foldl (&) (defaultOptions (Text.pack queueName)) o))
    (_, _, errs) ->
      return (Left (concat errs ++ help))

runDaemon :: Options -> IO ()
runDaemon =
  \case
    opts | opts ^. showHelp -> putStrLn help
    opts | opts ^. showVersion -> putStrLn "Version: ?"
    opts -> startDaemon (opts ^. daemonOptions)

main :: IO ()
main = do
  res <- getArgs >>= parseOptions
  case res of
    Left err   -> hPutStr stderr err
    Right opts -> runDaemon opts
