{-# LANGUAGE DoRec #-}
module Main
    where

import Control.Concurrent

import Control.Concurrent.Actors
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Applicative
import Control.Monad.IO.Class
import System.Random
import Control.Monad

main = do
    doRecTest
    --binaryTreeTest


------------------------------------------------
-- Testing the MonadFix instance for Actions:
--
--   I don't fully understand MonadFix, or whether there is a way to have it not
--   call 'error' in the MaybeT instance, but that is apparently correct
--   behavior.:
doRecTest = do
    putStrLn "Start"
    c <- newChan
    msgs <- getChanContents c
    --
    -- mutually-communicating actors:
    rec b1 <- spawn $ 
                Behavior $ do
                      send b2 "1"
                      m <- received
                      send c $ "1 received "++m
                      abort
        b2 <- spawn $ 
                Behavior $ do
                      send b3 "2" 
                      m <- received
                      send c $ "2 received "++m
                      abort
        b3 <- spawn $ 
                Behavior $ do
                      send b1 "3" 
                      m <- received
                      send c $ "3 received "++m
                      abort
    --
    -- sending the first message to "b3" starts the chain above:
    send b3 "main"
    mapM_ putStrLn $ take 3 msgs 
    putStrLn "done"


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
     m@(a',v) <- received
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


