{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Network.SQS.Daemon.Local
    ( startDaemon
    , DaemonOptions(..)
    ) where

import           Control.Lens
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Trans.AWS
import           Control.Monad.Trans.Resource
import           Data.CaseInsensitive
import           Data.HashMap.Strict          (HashMap)
import qualified Data.HashMap.Strict          as HM
import           Data.Monoid
import           Data.Text                    (Text, unpack)
import           Data.Text.Encoding
import           Data.Text.IO                 as Text
import           Network.AWS.SQS
import           Network.Wreq
import           System.IO
import           Text.Printf

data QueueUrls = QueueUrls { workerQueueUrl     :: Text
                           , deadLetterQueueUrl :: Text
                           }

say :: MonadIO m => Text -> m ()
say = liftIO . Text.putStrLn

getQueueUrl :: (MonadCatch a, MonadResource a) => Text -> AWST a Text
getQueueUrl = fmap (view gqursQueueURL) . send . getQueueURL

addAttributeHeaders :: Options
                    -> HashMap Text MessageAttributeValue
                    -> Options
addAttributeHeaders =
  HM.foldlWithKey' addHeader
  where
    addHeader opts' key attr =
      case attr ^. mavStringValue of
        Just value ->
          let headerName = mk ("x-aws-sqsd-attr-" <> encodeUtf8 key)
          in opts' & header headerName .~ [encodeUtf8 value]
        Nothing    -> opts'

deleteMessageByReceiptHandle :: (MonadCatch m, MonadResource m)
                             => Text
                             -> Text
                             -> AWST m ()
deleteMessageByReceiptHandle url receiptHandle = do
  void (send (deleteMessage url receiptHandle))
  liftIO (printf "Deleted message from queue: %s\n" url)

sendToDeadLetterQueueAndDelete :: (MonadCatch m, MonadResource m)
                             => QueueUrls
                             -> Text
                             -> Text
                             -> HashMap Text MessageAttributeValue
                             -> AWST m ()
sendToDeadLetterQueueAndDelete urls receiptHandle body attrs = do
  let dlqMsg = sendMessage (deadLetterQueueUrl urls) body
               & smMessageAttributes .~ attrs
  void (send dlqMsg)
  say "Sent message to dead letter queue, deleting."
  void (send (deleteMessage (workerQueueUrl urls) receiptHandle))

forwardMessage :: (MonadCatch m, MonadResource m)
               => Text
               -> QueueUrls
               -> Message
               -> AWST m ()
forwardMessage workerUrl urls msg =
  case (msg ^. mReceiptHandle, msg ^. mBody) of
    (Just receiptHandle, Just body) -> do
      let attrs = msg ^. mMessageAttributes
          opts = defaults `addAttributeHeaders` attrs
                 & header "content-type" .~ ["application/json"]
          req = postWith opts (unpack workerUrl) (encodeUtf8 body)
      result <- liftIO (try req)
      case result of
        Right res | res ^. responseStatus . statusCode == 200 ->
          deleteMessageByReceiptHandle (workerQueueUrl urls) receiptHandle
        Right res -> do
          liftIO (printf "Worker failed with status code: %d\n" (res ^. responseStatus . statusCode))
          sendToDeadLetterQueueAndDelete urls receiptHandle body attrs
        Left (e :: HttpException) -> do
          liftIO (printf "Worker request failed: %s\n" (show e))
          sendToDeadLetterQueueAndDelete urls receiptHandle body attrs

    (Nothing, _) -> say "Message had no reciept handle, ignoring."
    (_, Nothing) -> say "Message had no body, ignoring."

receiveNext :: (MonadCatch m, MonadResource m)
            => Text
            -> QueueUrls
            -> AWST m ()
receiveNext workerUrl urls = do
  msgs <- view rmrsMessages
         <$> send (receiveMessage (workerQueueUrl urls) & rmWaitTimeSeconds ?~ 20)
  unless (null msgs) $
    liftIO (printf "Received %d new messages, posting to worker.\n" (length msgs))
  forM_ msgs (forwardMessage workerUrl urls)


data DaemonOptions
  = DaemonOptions { workerUrl           :: Text
                  , workerQueueName     :: Text
                  , deadletterQueueName :: Text
                  }

startDaemon :: DaemonOptions
            -> IO ()
startDaemon (DaemonOptions {workerUrl, workerQueueName, deadletterQueueName}) = do
  let region = Ireland
  lgr <- newLogger Info stdout
  env <- newEnv region Discover <&> set envLogger lgr

  let sqsEndpoint = setEndpoint False "localhost" 9324 sqs

  runResourceT . runAWST env . within region $
    reconfigure sqsEndpoint $ do
      say "Starting local SQSD. Awaiting messages..."
      urls <- QueueUrls <$> getQueueUrl workerQueueName <*> getQueueUrl deadletterQueueName
      void (forever (receiveNext workerUrl urls))
