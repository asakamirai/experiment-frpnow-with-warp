{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified FRPNow.Counter as FRP

import qualified Network.Wai               as Wai
import qualified Network.Wai.Handler.Warp  as Warp
import qualified Network.HTTP.Types.Status as Status

import qualified Control.Concurrent.MVar as MVar

import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.Monoid                ((<>))
import qualified Data.Text                  as TXT

import           System.Timeout (timeout)

main :: IO ()
{-
main = FRP.testCounter
---}
--{-
main = do
    let port = 3000 -- とりあえずポート3000番で。
    let setting = Warp.setPort port Warp.defaultSettings
    putStrLn $ "start server port=" ++ show port
    input <- FRP.runCounter
    Warp.runSettings setting $ simpleApp input
---}

simpleApp :: FRP.InputIF FRP.Command -> Wai.Application
simpleApp input req respond = do
    let path = Wai.pathInfo req
    putStrLn $ "----- " ++ show path
    case path of
        ["add", numTxt] -> do
            let numStr = TXT.unpack numTxt
                num    = read numStr
                numBS  = LBS.pack numStr
            input $ FRP.AddCount num
            respond $ Wai.responseLBS Status.status200 [] $ "AddCount " <> numBS <> " accepted"
        ["start"] -> do
            input FRP.StartCount
            respond $ Wai.responseLBS Status.status200 [] "StartCount accepted"
        ["stop"] -> do
            input FRP.StopCount
            respond $ Wai.responseLBS Status.status200 [] "StopCount accepted"
        ["shutdown"] -> do
            input FRP.Shutdown
            respond $ Wai.responseLBS Status.status200 [] "Shutdown accepted"
        ["get"] -> do
            mv <- MVar.newEmptyMVar
            input $ FRP.GetCount $ MVar.putMVar mv
            mcount <- timeout 1000000 $ MVar.takeMVar mv
            case mcount of
                Just count -> respond . Wai.responseLBS Status.status200 [] . LBS.pack $ show count
                Nothing    -> respond $ Wai.responseLBS Status.status200 [] "timeout"
        _ -> do
            respond $ Wai.responseLBS Status.status200 [] "not supported command"

