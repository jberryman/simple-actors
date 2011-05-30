module Main
    where

import Control.Concurrent.Actors

main = spawnWriters 100

------------------------
spawnWriters n = do
    outBox <- newMailbox
    -- fork n actors. Each will write its number to the mailbox 'out'
    mapM_ (forkLoop . printerActor outBox) [1..n]
    -- fork n actors that will supply streams of () to the printerActors

    out <- receiveList outBox
    putStrLn $ unwords $ map show $ take (n*10) out

printerActor :: Mailbox Int -> Int -> Loop
printerActor b n = do
    send b n
    continue_ $ printerActor b n
    
------------------------


