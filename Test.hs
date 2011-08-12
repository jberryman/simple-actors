module Main
    where

import Control.Concurrent.Actors
import Control.Concurrent.Chan
import Control.Concurrent(forkIO,threadDelay)
import Control.Concurrent.MVar
import Control.Exception
import Data.Cofunctor

main = do
    forkActorQueueTest

------------------------
-- informal test that forkLocking is working:
forkActorQueueTest = do
    output <- newChan
    -- fork the actor to send numbers to whomever is listening to 's'. The sends
    -- inside the forked Actor_ will block until 's' has an Actor
    (b,s) <- newChanPair
    forkActor_ $ senderTo 1000 b
    forkActorUsing s $ sendInputTo output 200
    -- these will block 
    forkActorUsing s $ sendInputTo output 200
    forkActorUsing s $ sendInputTo output 200
    forkActorUsing s $ sendInputTo output 200
    forkActorUsing s $ sendInputTo output 200
     -- output should be in order because actor forks waited their turns above:
    getChanContents output >>=
        putStrLn . unwords . map show . take 1000
    putStrLn "DONE!"

sendInputTo :: Chan Int -> Int -> Actor Int
sendInputTo c n = Actor $ \i -> do
    send c i
    if n == 1 
        then done
        else continue $ sendInputTo c (n-1)

senderTo :: Int -> Mailbox Int -> Actor_
senderTo n c = Actor $ \_-> do
    send c n
    if n == 1
        then done
        else continue_ $ senderTo (n-1) c


------------------------
-- An example of catching BlockedIndefinitely and returning Bool:
{-
handleTest = let h :: SomeException -> IO Bool
                 h e = print e >> return False
                 l = sequence [newEmptyMVar, newEmptyMVar,newEmptyMVar,newEmptyMVar]
              in l >>= mapM (handle h . takeMVar) >>= print

handleTest2 = let h :: SomeException -> IO Bool
                  h e = print e >> return False
               in do v <- newEmptyMVar
                     mapM (handle h . takeMVar) [v,v,v,v] >>= print
-}


------------------------
-- A kind of "living binary tree"

binaryTree = do
    output <- newChan
    m <- forkActor $ treeNode
    undefined


treeNode = undefined



------------------------
------------------------
-- OLD:

main2 = do
    c <- newChan
    forkActor_ $ simpleFork_ c
    readChan c >>= print
    getChanContents c >>=
        mapM_ print . take 9

--  sends  10  messages to   the closed over chan.
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
 
-- actor prints its number to the closed over chan:
printerActor :: Chan Int -> Int -> Actor_
printerActor b n = Actor $ \_ -> do
    send b n
    continue_ $ printerActor b n
