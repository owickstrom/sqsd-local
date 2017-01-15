{-# LANGUAGE OverloadedStrings #-}
module Main where

import qualified Data.Text                as Text
import           Network.SQS.Daemon.Local
import           System.Environment

main :: IO ()
main = do
  args <- map Text.pack <$> getArgs
  case args of
    [workerUrl', workerQueueName', deadletterQueueName'] ->
      let options = DaemonOptions { workerUrl = workerUrl'
                                  , workerQueueName = workerQueueName'
                                  , deadletterQueueName = deadletterQueueName'
                                  }
      in startDaemon options
    _ ->
      putStrLn "Usage: sqsd-local WORKER_URL WORKER_QUEUE_NAME DEADLETTER_QUEUE_NAME"
