{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
#if __GLASGOW_HASKELL__ >= 800
{-# OPTIONS_GHC -freduction-depth=100 #-}
#else
{-# OPTIONS_GHC -fcontext-stack=100 #-}
#endif
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

#include "overlapping-compat.h"
module Servant.StreamSpec (spec) where

import           Control.Monad
                 (when)
import           Control.Monad.IO.Class
                 (MonadIO (..))
import           Control.Monad.Trans.Except
import qualified Data.ByteString            as BS
import           Data.Proxy
import qualified Data.TDigest               as TD
import qualified Network.HTTP.Client        as C
import           Prelude ()
import           Prelude.Compat
import           Servant.API
                 ((:<|>) ((:<|>)), (:>), JSON, NetstringFraming,
                 NewlineFraming, NoFraming, OctetStream, SourceIO, StreamGet)
import           Servant.Client
import           Servant.ClientSpec
                 (Person (..))
import qualified Servant.ClientSpec         as CS
import           Servant.Server
import           Servant.Types.Codensity
                 (Codensity (..))
import           Servant.Types.SourceT
import           System.Entropy
                 (getEntropy, getHardwareEntropy)
import           System.IO.Unsafe
                 (unsafePerformIO)
import           System.Mem
                 (performGC)
import           Test.Hspec

#if MIN_VERSION_base(4,10,0)
import           GHC.Stats
                 (gc, gcdetails_live_bytes, getRTSStats)
#else
import           GHC.Stats
                 (currentBytesUsed, getGCStats)
#endif

spec :: Spec
spec = describe "Servant.Stream" $ do
    streamSpec

type StreamApi =
         "streamGetNewline" :> StreamGet NewlineFraming JSON (SourceIO Person)
    :<|> "streamGetNetstring" :> StreamGet NetstringFraming JSON (SourceIO Person)
    :<|> "streamALot" :> StreamGet NoFraming OctetStream (SourceIO BS.ByteString)

api :: Proxy StreamApi
api = Proxy

getGetNL, getGetNS :: ClientM (Codensity IO (SourceIO Person))
getGetALot :: ClientM (Codensity IO (SourceIO BS.ByteString))
getGetNL :<|> getGetNS :<|> getGetALot = client api

alice :: Person
alice = Person "Alice" 42

bob :: Person
bob = Person "Bob" 25

server :: Application
server = serve api
    $    return (source [alice, bob, alice])
    :<|> return (source [alice, bob, alice])

    -- 2 ^ (18 + 10) = 256M
    :<|> return (SourceT ($ lots (powerOfTwo 18)))
  where
    lots n
        | n < 0     = Stop
        | otherwise = Effect $ do
            let size = powerOfTwo 10
            mbs <- getHardwareEntropy size
            bs <- maybe (getEntropy size) pure mbs
            return (Yield bs (lots (n - 1)))

powerOfTwo :: Int -> Int
powerOfTwo = (2 ^)

{-# NOINLINE manager' #-}
manager' :: C.Manager
manager' = unsafePerformIO $ C.newManager C.defaultManagerSettings

runClient :: ClientM a -> BaseUrl -> IO (Either ServantError a)
runClient x baseUrl' = runClientM x (mkClientEnv manager' baseUrl')

testRunSourceIO :: Codensity IO (SourceIO a)
    -> IO (Either String [a])
testRunSourceIO = runExceptT . runSourceT . joinCodensitySourceT

streamSpec :: Spec
streamSpec = beforeAll (CS.startWaiApp server) $ afterAll CS.endWaiApp $ do
    it "works with Servant.API.StreamGet.Newline" $ \(_, baseUrl) -> do
        Right res <- runClient getGetNL baseUrl
        testRunSourceIO res `shouldReturn` Right [alice, bob, alice]

    it "works with Servant.API.StreamGet.Netstring" $ \(_, baseUrl) -> do
        Right res <- runClient getGetNS baseUrl
        testRunSourceIO res `shouldReturn` Right [alice, bob, alice]

    it "streams in constant memory" $ \(_, baseUrl) -> do
        Right rs <- runClient getGetALot baseUrl
        performGC
        -- usage0 <- getUsage
        -- putStrLn $ "Start:  " ++ show usage0
        tdigest <- memoryUsage $ joinCodensitySourceT rs

        -- putStrLn $ "Median: " ++ show (TD.median tdigest)
        -- putStrLn $ "Mean:   " ++ show (TD.mean tdigest)
        -- putStrLn $ "Stddev: " ++ show (TD.stddev tdigest)

        -- forM_ [0.01, 0.1, 0.2, 0.5, 0.8, 0.9, 0.99] $ \q ->
        --    putStrLn $ "q" ++ show q ++ ": " ++ show (TD.quantile q tdigest)

        let Just stddev = TD.stddev tdigest

        -- standard deviation of 100k is ok, we generate 256M of data after all.
        -- On my machine deviation is 40k-50k
        stddev `shouldSatisfy` (< 100000)

memoryUsage :: SourceT IO BS.ByteString -> IO (TD.TDigest 25)
memoryUsage src = unSourceT src $ loop mempty (0 :: Int)
  where
    loop !acc !_ Stop          = return acc
    loop !_   !_ (Error err)   = fail err -- !
    loop !acc !n (Skip s)      = loop acc n s
    loop !acc !n (Effect ms)   = ms >>= loop acc n
    loop !acc !n (Yield _bs s) =  do
        usage  <- liftIO getUsage
        -- We perform GC in between as we generate garbage.
        when (n `mod` 1024 == 0) $ liftIO performGC
        loop (TD.insert usage acc) (n + 1) s

getUsage :: IO Double
getUsage = fromIntegral .
#if MIN_VERSION_base(4,10,0)
    gcdetails_live_bytes . gc <$> getRTSStats
#else
    currentBytesUsed <$> getGCStats
#endif
