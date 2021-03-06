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
import qualified Control.Concurrent.Chan   as Chan
import qualified Control.Concurrent.MVar   as MV
import qualified Control.Exception         as E
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

getGetCount :: Command -> Maybe (InputIF Int)
getGetCount (GetCount inIF) = Just inIF
getGetCount _               = Nothing

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
        getCountStream   = getGetCount   `FRP.filterMapEs` inputStream
        shutdownStream   = getShutdown   `FRP.filterMapEs` inputStream
    -- 秒カウントのEvStreamを生成
    secStream <- genSecStream
    -- countStateStreamの最後のイベントの値を表すBehaviorを作成
    countingState <- FRP.sampleNow $ False `FRP.fromChanges` countStateStream
    -- countStateがTrueの間だけ、秒カウントするEvStreamを作成
    let secCountStream   = secStream `FRP.during` countingState
    -- addCountStreamとsecCountStreamのイベントをマージしたEvStreamを作成
    let countUpStream    = secCountStream `FRP.merge` addCountStream
    -- countUpStreamの内容を合算した状態を表すBehaviorを作成
    countState <- FRP.sampleNow $ FRP.foldEs (+) 0 countUpStream
    -- GetCountイベントに、そのときのcounterの値を応答させる
    respondToGetCount countState `FRP.callStream` getCountStream
    -- counterの値が変化するたびに、その値をコンソールに出力する
    (putStrLn . ("count " ++) . show) `FRP.callIOStream` FRP.toChanges countState
    -- 最初に来たShutdownイベントを取り出して返す
    -- このイベントが届くとFRPの実行が終了する
    FRP.sampleNow $ FRP.next shutdownStream
    where
        -- | GetCountコマンドに応答する
        respondToGetCount :: Behavior Int -> [InputIF Int] -> Now ()
        respondToGetCount countState inIFs = do
            -- counterの値を採取する。
            count <- FRP.sampleNow countState
            -- コンソールに表示してGetCountイベントに応答
            FRP.sync $ do
                putStrLn $ "respond to GetCount : " ++ show count
                -- 「同時」に届いたGetCountイベントはリストになって渡されるので全てに同じ値を渡す
                M.forM_ inIFs ($ count)
        -- | １秒ごとにイベント（内容はIntの１）を発行するEvStreamを生成する。
        --   終了をサポートしていないので、放置するとリークする。今は気にしない。
        genSecStream :: Now (EvStream Int)
        genSecStream = do
            (evs, emitEv) <- FRP.callbackStream
            FRP.sync . M.void . AS.async . M.forever $ do
                emitEv 1
                CC.threadDelay 1000000
            return evs

-- | 入力EvStreamを受け取るNowモナドを実行する。
--   返り値は、入力EvStreamへの入力アクション。
runNow :: (EvStream a -> Now (Event x)) -> IO (InputIF a)
runNow now = do
    -- frpnow側が多数のスレッドからの同時イベント発行に対応していない
    -- ように見えるので、チャネルを設けてタイミング制御を行っている。
    -- が、これで正しく動く保証はない。
    mvEmitEv <- MV.newEmptyMVar
    mvWait   <- MV.newEmptyMVar
    M.void . AS.async . FRP.runNowMaster $ do
        (inputStream, emitEv) <- FRP.callbackStream
        M.void . FRP.sync $ mvEmitEv `MV.putMVar` emitEv
        MV.putMVar mvWait `FRP.callIOStream` inputStream
        now inputStream
    emitEv <- MV.takeMVar mvEmitEv
    chan <- Chan.newChan
    M.void . AS.async . E.handle handleException . M.forever $ do
        a <- Chan.readChan chan
        emitEv a
        M.void $ MV.takeMVar mvWait
    return $ Chan.writeChan chan
    where
        handleException (E.SomeException _err) = return ()

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

