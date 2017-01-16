{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
module Network.SQS.Daemon.Local
    ( startDaemon
    , DaemonOptions(..)
    , workerUrl
    , workerQueueName
    , deadLetterQueueName
    , httpTimeout
    , contentType
    , sqsHost
    , sqsPort
    , forked
    ) where

import           Control.Concurrent.Lifted
import           Control.Lens
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Trans.AWS
import           Control.Monad.Trans.Resource
import           Data.ByteString              (ByteString)
import           Data.CaseInsensitive
import           Data.HashMap.Strict          (HashMap)
import qualified Data.HashMap.Strict          as HM
import           Data.Maybe
import           Data.Monoid
import           Data.Text                    (Text)
import qualified Data.Text                    as Text
import           Data.Text.Encoding
import           Data.Text.IO                 as Text
import           Network.AWS.SQS
import           Network.HTTP.Client          (defaultManagerSettings,
                                               managerResponseTimeout)
import           Network.Wreq
import           System.IO
import           Text.Printf

data DaemonOptions
  = DaemonOptions { _workerUrl           :: Text
                  , _workerQueueName     :: Text
                  , _deadLetterQueueName :: Maybe Text
                  , _httpTimeout         :: Maybe Int
                  , _contentType         :: ByteString
                  , _sqsHost             :: ByteString
                  , _sqsPort             :: Int
                  , _forked :: Bool
                  } deriving (Show, Eq, Ord)

makeLenses ''DaemonOptions

data WithUrls o
  = WithUrls { _daemonOptions      :: o
             , _workerQueueUrl     :: Text
             , _deadLetterQueueUrl :: Maybe Text
             } deriving (Show, Eq, Ord)

makeLenses ''WithUrls

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
                             => WithUrls DaemonOptions
                             -> Text
                             -> Text
                             -> HashMap Text MessageAttributeValue
                             -> AWST m ()
sendToDeadLetterQueueAndDelete opts receiptHandle body attrs = do
  -- Only send to dead letter queue if specified.
  case opts ^. deadLetterQueueUrl of
    Just dlqUrl -> do
      let dlqMsg = sendMessage dlqUrl body
                   & smMessageAttributes .~ attrs
      void (send dlqMsg)
      say "Sent message to dead letter queue."
    Nothing -> return ()

  say "Deleting handled message from worker queue."
  void (send (deleteMessage (opts ^. workerQueueUrl) receiptHandle))


forwardMessage :: (MonadCatch m, MonadResource m)
               => WithUrls DaemonOptions
               -> Message
               -> AWST m ()
forwardMessage o msg =
  case (msg ^. mReceiptHandle, msg ^. mBody) of
    (Just receiptHandle, Just body) -> do
      let attrs = msg ^. mMessageAttributes
          timeout' = (* 1000000) <$> o ^. daemonOptions . httpTimeout
          opts = defaults `addAttributeHeaders` attrs
                 & header "content-type" .~ [o ^. daemonOptions . contentType]
                 & manager .~ Left (defaultManagerSettings { managerResponseTimeout = timeout' })
          req = postWith opts (Text.unpack (o ^. daemonOptions . workerUrl)) (encodeUtf8 body)
      result <- liftIO (try req)
      case result of
        Right res | res ^. responseStatus . statusCode == 200 ->
          deleteMessageByReceiptHandle (o ^. workerQueueUrl) receiptHandle
        Right res -> do
          liftIO (printf "Worker failed with status code: %d\n" (res ^. responseStatus . statusCode))
          sendToDeadLetterQueueAndDelete o receiptHandle body attrs
        Left (e :: HttpException) -> do
          liftIO (printf "Worker request failed: %s\n" (show e))
          sendToDeadLetterQueueAndDelete o receiptHandle body attrs

    (Nothing, _) -> say "Message had no reciept handle, ignoring."
    (_, Nothing) -> say "Message had no body, ignoring."


receiveNext :: (MonadCatch m, MonadResource m, MonadBaseControl IO m)
            => WithUrls DaemonOptions
            -> AWST m ()
receiveNext o = do
  msgs <- view rmrsMessages
         <$> send (receiveMessage (o ^. workerQueueUrl)
                   & rmMaxNumberOfMessages ?~ 10
                   & rmWaitTimeSeconds ?~ 20)


  unless (Prelude.null msgs) $
    let forkedMsg = if o ^. daemonOptions . forked
                    then "concurrent"
                    else "serialized"
    in liftIO (printf "Received %d new messages, posting to worker (%s).\n"
               (Prelude.length msgs)
               (forkedMsg :: String))

  let process = if o ^. daemonOptions . forked then void . fork else void
  forM_ msgs (process . forwardMessage o)


startDaemon :: DaemonOptions
            -> IO ()
startDaemon opts = do
  lgr <- newLogger Info stdout
  env <- newEnv Ireland Discover <&> set envLogger lgr

  let sqsEndpoint = setEndpoint False (opts ^. sqsHost) (opts ^. sqsPort) sqs

  runResourceT . runAWST env $
    reconfigure sqsEndpoint $ do
      o <- WithUrls opts
          <$> getQueueUrl (opts ^. workerQueueName)
          <*> maybe (return Nothing) (fmap Just . getQueueUrl) (opts ^. deadLetterQueueName)

      when (isNothing (o ^. deadLetterQueueUrl)) $
        say "No dead letter queue specified."

      say "Starting local SQSD. Awaiting messages..."
      void (forever (receiveNext o))
