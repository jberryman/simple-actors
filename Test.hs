module Main
    where

import Control.Concurrent.Actors
import Control.Concurrent.Chan
import Control.Concurrent(forkIO,threadDelay)
import Control.Concurrent.MVar
import Control.Exception
import Data.Cofunctor
import Control.Applicative
import Control.Monad.IO.Class
import System.Random
import Control.Monad

main = do
    recoverTest
    --spawnTest
    --binaryTreeTest

------------------------------------------------
-- A test of actor resumption and recovery
recoverTest = do
{-
    ----alternative instance
    out <- newChan
    m <- spawn $ altBehavior out
    -- this should block, but doesn't. Why?
    --mapM_ (send m) [1..10]
    mapM_ (send m) [1..5]
    getChanContents out >>= mapM_ putStrLn . take 11
    -- this blocks:
    --send m 0
-}
-- TODO: figure out why we get a deadlock here:
    ----starting queueing
    out <- newChan
    --threadDelay 999999
    t5 <- spawn takes5
    --threadDelay 999999
    (b,a) <- spawnIdle
    --threadDelay 999999
    spawn_ (Behavior $ mapM_ (send b) [1..] >> mzero)

    --threadDelay 999999
    putStrLn "first starting"
    a `starting` naiveSender out t5

    --threadDelay 999999
    putStrLn "second starting"
    a `starting` recoverFromNaive out
    
    --threadDelay 999999
    getChanContents out >>= mapM_ putStrLn

    

altBehavior out = Behavior $ 
        do send out "first started" 
           n <- receive
           guard (n < 5)
           send out ("first received: "++show n)
           return $ altBehavior out
    <|> do send out "second started"
           n <- receive
           send out ("second received: "++show n++", exiting")
           stop

-- for testing recovery with `strarting` queueuing:
takes5 = Behavior $ do
    n <- receive
    guard (n < 6)
    return takes5

-- expects receiver to stay receiving forever:
naiveSender out m = Behavior $ do
    n <- receive 
    send out $ "naively sending: "++(show n)
    send m n
    return $ naiveSender out m

recoverFromNaive out = Behavior $ do
    n <- receive 
    send out $ "recovered on input: " ++ show n
    stop


------------------------------------------------
-- informal test that forkLocking is working:
spawnTest = do
    output <- newChan
    -- fork the actor to send numbers to whomever is listening to 's'. The sends
    -- inside the forked Actor_ will block until 's' has an Actor
    (b,a) <- spawnIdle
    spawn_ $ senderTo 1000 b

    -- start a behavior
    a `starting` sendInputTo output 200
    -- these will block while beh above is running
    a `starting` sendInputTo output 200
    a `starting` sendInputTo output 200
    a `starting` sendInputTo output 200
    a `starting` sendInputTo output 200

     -- output should be in order because actor forks waited their turns above:
    getChanContents output >>=
        putStrLn . unwords . map show . take 1000
    putStrLn "DONE!"


sendInputTo :: Chan Int -> Int -> Behavior Int
sendInputTo c n = Behavior $ do
    i <- receive
    send c i
     -- halt if not equal to 1
    guard (n /= 1)
    return $ sendInputTo c (n-1)

senderTo :: Int -> Mailbox Int -> Behavior a
senderTo n c = Behavior $ do
    send c n
    guard $ n /= 1
    return $ senderTo (n-1) c


------------------------------------------------
-- A kind of "living binary tree"

-- we support an add operation that fills an MVar with a Bool set to True if the
-- Int passed was added to the tree. False if it was already present:
type Message = (Int, MVar Bool)

type Node = Mailbox Message
type RootNode = Node

addValue :: MonadIO m=> Int -> RootNode -> m Bool
addValue a nd = liftIO $ do
    v <- newEmptyMVar
    send nd (a,v)
    takeMVar v



-- This is the Behavior of interest that defines our tree node actor's behavior.
-- It is closed over Maybe its left and right child nodes, as well as its own
-- node value.
-- On receiving a message it compares the enclosed value to its own value and
-- either sends it down toa child node (creating if doesn't exist) or if equal
-- to the current node, report back False to the passed MVar, indicating that
-- the value was already present.
-- The behavior then recurses, closing over any newly created child node.
treeNode :: Maybe Node -> Maybe Node -> Int -> Behavior Message
treeNode l r a = Behavior $ do
     m@(a',v) <- receive
     let addToChild = fmap Just . maybe newNode passToChild
         newNode = send v True >> initTree a'
         passToChild c = c <$ send c m
     case compare a' a of
          -- signal that node was present and return:
          EQ -> send v False >> return (treeNode l r a)
          -- return new behavior closed over possibly newly-created child nodes:
          LT -> (\l'-> treeNode l' r a) <$> addToChild l
          GT -> (\r'-> treeNode l r' a) <$> addToChild r



-- create a new tree from an initial element. used to make branches internally
initTree :: MonadIO m=> Int -> m Node
initTree = spawn . treeNode Nothing Nothing
    


----
---- The following is all code to test the binary tree actor we implemented above:
----

binaryTreeTest = do
    -- all output by forked actors goes into this Chan:
    output <- newChan
    -- create a new tree from an initial value
    root <- initTree 0
    -- FORK 10 WRITERS TO THE TREE
    mapM_ (spawn_ . writeRandsTo root output 1000) ['a'..'z']
    -- print ourput from chan:
    getChanContents output >>= mapM (putStrLn . show) . take (26*1000)



-- Lift an RNG to an Action. A non-abstraction-breaking use of liftIO here, IMHO
randInt :: Action a Int
randInt = liftIO $ randomRIO (-5000,5000) 


type Name = Char
type OutMessage = (Name,Bool,Int)


-- we also use an Actor to write our values to the tree
writeRandsTo :: RootNode -> Chan OutMessage -> Int -> Name -> Behavior a
writeRandsTo root out n name = Behavior $ do
    guard (n /= 0)
    -- a random stream of ints:
    i <- randInt
    -- add them into the tree, returning a list of the results:
    b <- i `addValue` root
    -- report back input, result, and the name of this actor:
    send out (name,b,i)
    return $ writeRandsTo root out (n-1) name


