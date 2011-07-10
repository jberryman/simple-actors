module Main
    where

import Control.Concurrent.Actors

main = 
    main2

------------------------
main2 = do
    (b,str) <- newChanPair
    forkActor_ $ simpleFork_ b
    -- WORKS:
    receive str >>= print

    -- BROKEN:
    receiveList str >>=
        mapM_ print . take 100

simpleFork_ :: Mailbox Int -> Actor_
simpleFork_ b = Actor $ \_-> do
    mapM (send b) [1..10]
    done

------------------------
-- BROKEN:

main1 = spawnWriters 100

spawnWriters n = do
    (mb,ioStr) <- newChanPair
    -- fork n actors. Each will write its number to the mailbox 'out'
    mapM_ (forkActor_ . printerActor mb) [1..n]

    receiveList ioStr >>=
        putStrLn . unwords . map show . take (n*10) 

printerActor :: Mailbox Int -> Int -> Actor_
printerActor b n = Actor $ \_ -> do
    send b n
    continue_ $ printerActor b n
    
------------------------


