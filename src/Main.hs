{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Main where

import           Control.Lens
import qualified Data.ByteString.Char8    as BS
import           Data.Text                (Text)
import qualified Data.Text                as Text
import           Network.SQS.Daemon.Local
import           System.Console.GetOpt
import           System.Environment
import           System.IO
import           Text.Printf

import qualified Data.Version             as Version
import           Paths_sqsd_local

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
                                           , _contentType = BS.pack "application/octet-stream"
                                           , _sqsHost = BS.pack "localhost"
                                           , _sqsPort = 9324
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
    "Specify the worker URL to send POST requests to (default: http://localhost:5000)"
  , Option "d" ["dead-letter-queue-name"]
    (ReqArg (set (daemonOptions . deadLetterQueueName) . Just . Text.pack) "NAME")
    "Name of the SQS queue to send messages to which the worker failed processing (no default)"
  , Option "T" ["http-timeout"]
    (ReqArg (set (daemonOptions . httpTimeout) . readMaybe) "NAME")
    "Timeout in seconds for the HTTP POST request to worker (default: 30)"
  , Option "C" ["content-type"]
    (ReqArg (set (daemonOptions . contentType) . BS.pack) "MEDIA_TYPE")
    "Content-Type header value to use in HTTP POST request to worker (default: application/octet-stream)"
  , Option "" ["sqs-host"]
    (ReqArg (set (daemonOptions . sqsHost) . BS.pack) "MEDIA_TYPE")
    "SQS endpoint host (default: localhost)"
  , Option "" ["sqs-port"]
    (ReqArg (set (daemonOptions . sqsPort) . maybe 9324 id . readMaybe) "MEDIA_TYPE")
    "SQS endpoint port (default: 9324)"
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
    opts | opts ^. showHelp -> hPutStr stderr help
    opts | opts ^. showVersion -> hPutStrLn stderr (Version.showVersion version)
    opts -> startDaemon (opts ^. daemonOptions)

main :: IO ()
main = do
  res <- getArgs >>= parseOptions
  case res of
    Left err   -> hPutStr stderr err
    Right opts -> runDaemon opts
