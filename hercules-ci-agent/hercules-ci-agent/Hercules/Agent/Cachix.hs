module Hercules.Agent.Cachix
  ( module Hercules.Agent.Cachix,
    activePushCaches,
  )
where

import qualified Cachix.Client.Push as Cachix.Push
import Control.Monad.IO.Unlift
import qualified Data.Map as M
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Hercules.Agent.Cachix.Env as Agent.Cachix
import Hercules.Agent.Cachix.Info (activePushCaches)
import Hercules.Agent.Env as Agent.Env
import qualified Hercules.Agent.EnvironmentInfo as EnvInfo
import Hercules.Agent.Log
import qualified Hercules.Agent.Nix as Nix
import qualified Hercules.Agent.SecureDirectory as SecureDirectory
import Hercules.Error
import qualified Hercules.Formats.CachixCache as CachixCache
import Protolude
import System.IO (hClose)

push :: Text -> [Text] -> Int -> App ()
push cache paths workers = withNamedContext "cache" cache $ do
  Agent.Cachix.Env
    { pushCaches = pushCaches,
      nixStore = nixStore,
      clientEnv = clientEnv
    } <-
    asks $ Agent.Cachix.getEnv
  pushCache <-
    escalate
      $ maybeToEither (FatalError $ "Cache not found " <> cache)
      $ M.lookup cache pushCaches
  ul <- askUnliftIO
  void $
    Cachix.Push.pushClosure
      ( \f l ->
          liftIO $ Cachix.Push.mapConcurrentlyBounded workers (fmap (unliftIO ul) f) l
      )
      clientEnv
      nixStore
      pushCache
      ( \storePath ->
          let ctx = withNamedContext "path" storePath
           in Cachix.Push.PushStrategy
                { onAlreadyPresent = pass,
                  onAttempt = \retryStatus size ->
                    ctx
                      $ withNamedContext "size" size
                      $ withNamedContext "retry" (show retryStatus :: Text)
                      $ logLocM DebugS "pushing",
                  on401 = throwIO $ FatalError $ "Cachix push is unauthorized",
                  onError = \err -> throwIO $ FatalError $ "Error pushing to cachix: " <> show err,
                  onDone = ctx $ logLocM DebugS "push done",
                  withXzipCompressor = Cachix.Push.defaultWithXzipCompressor
                }
      )
      paths

getNetrcLines :: App [Text]
getNetrcLines = asks (Agent.Cachix.netrcLines . Agent.Env.cachixEnv)

getSubstituters :: App [Text]
getSubstituters = do
  cks <- asks (Agent.Cachix.cacheKeys . Agent.Env.cachixEnv)
  nixInfo <- liftIO EnvInfo.getNixInfo
  pure
    ( EnvInfo.nixSubstituters nixInfo
        ++ map (\c -> "https://" <> c <> ".cachix.org") (M.keys cks)
    )

getTrustedPublicKeys :: App [Text]
getTrustedPublicKeys = do
  cks <- asks (Agent.Cachix.cacheKeys . Agent.Env.cachixEnv)
  nixInfo <- liftIO EnvInfo.getNixInfo
  pure (EnvInfo.nixTrustedPublicKeys nixInfo ++ concatMap CachixCache.publicKeys cks)

withCaches :: App a -> App a
withCaches m = do
  netrcLns <- getNetrcLines
  substs <- getSubstituters
  pubkeys <- getTrustedPublicKeys
  SecureDirectory.withSecureTempFile "tmp-netrc.key" $ \netrcPath netrcHandle -> do
    liftIO $ do
      Text.hPutStrLn netrcHandle (Text.unlines netrcLns)
      hClose netrcHandle
    Nix.withExtraOptions
      [ ("netrc-file", toSL netrcPath),
        ("substituters", Text.intercalate " " substs),
        ("trusted-public-keys", Text.intercalate " " pubkeys)
      ]
      m
