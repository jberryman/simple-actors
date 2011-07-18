module Main
    where

import Control.Concurrent.Actors
import Control.Concurrent.Chan

main = do
    main1
    main2

------------------------
main2 = do
    c <- newChan
    forkActor_ $ simpleFork_ c
    readChan c >>= print
    getChanContents c >>=
        mapM_ print . take 9

simpleFork_ :: Chan Int -> Actor_
simpleFork_ c = Actor $ \_-> do
    mapM (send c) [1..10]
    done

------------------------
main1 = spawnWriters 100

spawnWriters n = do
    c <- newChan
    -- fork n actors. Each will write its number to the mailbox 'out'
    mapM_ (forkActor_ . printerActor c) [1..n]

    getChanContents c >>=
        putStrLn . unwords . map show . take (n*10) 

printerActor :: Chan Int -> Int -> Actor_
printerActor b n = Actor $ \_ -> do
    send b n
    continue_ $ printerActor b n
------------------------

main3 = do
    undefined
