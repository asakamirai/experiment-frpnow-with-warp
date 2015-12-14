{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}

module FRPNow.Counter
    ( runNow
    , setupCounter
    , runCounter
    , testCounter
    , Command(..)
    , InputIF
    ) where

import qualified Control.Concurrent        as CC
import qualified Control.Concurrent.Async  as AS
import qualified Control.Concurrent.MVar   as MV
import qualified Control.FRPNow            as FRP
import           Control.FRPNow            (Behavior, Event, EvStream, Now)
import qualified Control.Monad             as M

type InputIF a = a -> IO ()

data Command =
      StartCount
    | StopCount
    | AddCount Int
    | GetCount (InputIF Int)
    | Shutdown

instance Show Command where
    show StartCount   = "StartCount"
    show StopCount    = "StopCount"
    show (AddCount a) = "AddCount " ++ show a
    show (GetCount _) = "GetCount"
    show Shutdown     = "Shutdown"

getCount :: Command -> Maybe (InputIF Int)
getCount (GetCount inIF) = Just inIF
getCount _               = Nothing

getCountState :: Command -> Maybe Bool
getCountState StartCount = Just True
getCountState StopCount  = Just False
getCountState _          = Nothing

getAddCount :: Command -> Maybe Int
getAddCount (AddCount x) = Just x
getAddCount _            = Nothing

getShutdown :: Command -> Maybe ()
getShutdown Shutdown = Just ()
getShutdown _        = Nothing

-- | カウンターをセットアップする。
setupCounter :: EvStream Command -> Now (Event ())
setupCounter inputStream = do
    -- inputStreamを４つのEvStreamに分ける
    -- StartCount/StopCountはTrue/Falseに変換してひとつのEvStreamに。
    let addCountStream   = getAddCount   `FRP.filterMapEs` inputStream
        countStateStream = getCountState `FRP.filterMapEs` inputStream
        getCountStream   = getCount      `FRP.filterMapEs` inputStream
        shutdownStream   = getShutdown   `FRP.filterMapEs` inputStream
    -- 秒カウントのEvStreamを生成する
    secStream <- genSecStream
    -- countStateStreamの最後のイベントの値を表すBehaviorを作成。
    countState <- FRP.sampleNow $ False `FRP.fromChanges` countStateStream
    -- countStateがTrueの間だけ、秒カウントするEvStream。
    let secCountStream   = secStream `FRP.during` countState
    -- addCountStreamとsecCountStreamのイベントをマージしたEvStream
    let countUpStream    = secCountStream `FRP.merge` addCountStream
    -- countUpStreamの内容を合算した状態を表すBehaviorを作成。
    counter <- FRP.sampleNow $ FRP.foldEs (+) 0 countUpStream
    -- GetCountイベントに、そのときのcounterの値を応答する
    respondToGetCount counter `FRP.callStream` getCountStream
    -- counterの値が変化するたびに、その値をコンソールに出力する
    (putStrLn . ("count " ++) . show) `FRP.callIOStream` FRP.toChanges counter
    -- 最初に来たShutdownイベントを取り出して返す。
    -- このイベントが届くとFRPの実行が終了する。
    FRP.sampleNow $ FRP.next shutdownStream
    where
        -- | GetCountコマンドに応答する。
        --   「同時」に届いたGetCountイベントはリストになって渡される。
        respondToGetCount :: Behavior Int -> [InputIF Int] -> Now ()
        respondToGetCount counter inIFs = do
            -- counterの値を採取する。
            count <- FRP.sampleNow counter
            -- コンソールに表示してGetCountイベントに応答する。
            FRP.sync $ do
                putStrLn $ "respond to GetCount : " ++ show count
                M.forM_ inIFs ($ count)
        -- | １秒ごとにイベント（内容はIntの１）を発行するEvStreamを生成する。
        genSecStream :: Now (EvStream Int)
        genSecStream = do
            (evs, emitEv) <- FRP.callbackStream
            FRP.sync . M.void . AS.async . M.forever $ do
                emitEv 1
                CC.threadDelay 1000000
            return evs

runNow :: (EvStream a -> Now (Event x)) -> IO (InputIF a)
runNow now = do
    mv <- MV.newEmptyMVar
    M.void . AS.async . FRP.runNowMaster $ do
        (inputStream, emitEv) <- FRP.callbackStream
        M.void . FRP.sync $ mv `MV.putMVar` emitEv
        now inputStream
    MV.takeMVar mv

runCounter :: IO (InputIF Command)
runCounter = runNow setupCounter

testCounter :: IO ()
testCounter = do
    input <- runCounter
    loop input
    putStrLn "----- end"
    where
        loop input = do
            CC.threadDelay $ 500000
            startCount
            CC.threadDelay $ 2000000
            printCount
            CC.threadDelay $ 2000000
            stopCount
            CC.threadDelay $ 2000000
            printCount
            CC.threadDelay $ 2000000
            printCount
            addCount 10
            printCount
            CC.threadDelay $ 5000000
            putStrLn "-------------------"
            startCount
            CC.threadDelay $ 2000000
            printCount
            CC.threadDelay $ 2000000
            shutdown
            CC.threadDelay $ 2000000
            printCount
            CC.threadDelay $ 2000000
            where
                startCount :: IO ()
                startCount = do
                    putStrLn "Send StartCount"
                    input StartCount
                stopCount :: IO ()
                stopCount  = do
                    putStrLn "Send StopCount"
                    input StopCount
                shutdown :: IO ()
                shutdown   = do
                    putStrLn "Send Shutdown"
                    input Shutdown
                printCount :: IO ()
                printCount = do
                    putStrLn "Send GetCount"
                    input . GetCount $ putStrLn . (("Got ") ++) . show
                addCount :: Int -> IO ()
                addCount num = do
                    putStrLn $ "Send AddCount : " ++ show num
                    input $ AddCount num

