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

main = do
    --forkActorQueueTest
    binaryTreeTest

------------------------
-- informal test that forkLocking is working:
forkActorQueueTest = do
    output <- newChan
    -- fork the actor to send numbers to whomever is listening to 's'. The sends
    -- inside the forked Actor_ will block until 's' has an Actor
    (b,a) <- forkActor
    forkActorDoing_ $ senderTo 1000 b

    -- TODO: consider to avoid parens, defining:
    --     doingBehavior a b = a `doing` (behavior b)
    -- or making behavior short function named:
    --     beh
    -- in which case we would have:
    --     doingBeh
    -- there is no need for a doingBeh_ variant since it goes nicely before the
    -- 'do' in function decls. Another alternative:
    --     'behaving'
    a `doing` sendInputTo output 200
    -- these will block 
    a `doing` sendInputTo output 200
    a `doing` sendInputTo output 200
    a `doing` sendInputTo output 200
    a `doing` sendInputTo output 200

     -- output should be in order because actor forks waited their turns above:
    getChanContents output >>=
        putStrLn . unwords . map show . take 1000
    putStrLn "DONE!"


-- TODO: consider if we should export a BehaviorStep type synonym. Alternatively
-- we might do: UnwrappedBehavior, or something to that effect
sendInputTo :: Chan Int -> Int -> Behavior Int
sendInputTo c n = Recv $ \i-> do
    send c i
    -- TODO: Consider defining:
    -- elseReturn b a = if b then done else return a
    -- actually something named like guard would be better:
    return $ if n == 1 
             then Idle
             else sendInputTo c (n-1)

senderTo :: Int -> Mailbox Int -> Behavior_
senderTo n c = ignoring $ do
    send c n
    return $ if n == 1
             then Idle
             else senderTo (n-1) c


------------------------
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
treeNode l r a = Recv $ \m@(a',v)->

  let addToChild = fmap Just . maybe newNode passToChild
      newNode = send v True >> initTree a'
      passToChild c = c <$ send c m

   in case compare a' a of
           -- signal that node was present and return:
           EQ -> send v False >> return (treeNode l r a)
           -- return new behavior closed over possibly newly-created child nodes:
           LT -> (\l'-> treeNode l' r a) <$> addToChild l
           GT -> (\r'-> treeNode l r' a) <$> addToChild r



-- create a new tree from an initial element. used to make branches internally
initTree :: MonadIO m=> Int -> m Node
initTree = forkActorDoing . treeNode Nothing Nothing
    


----
---- The following is all code to test the binary tree actor we implemented above:
----

binaryTreeTest = do
    -- all output by forked actors goes into this Chan:
    output <- newChan
    -- create a new tree from an initial value
    root <- initTree 0
    -- FORK 10 WRITERS TO THE TREE
    mapM_ (forkActorDoing_ . writeRandsTo root output 1000) ['a'..'z']
    -- print ourput from chan:
    getChanContents output >>= mapM (putStrLn . show) . take (26*1000)



-- Lift an RNG to an Action. A non-abstraction-breaking use of liftIO here, IMHO
randInt :: Action Int
randInt = liftIO $ randomRIO (-5000,5000) 


type Name = Char
type OutMessage = (Name,Bool,Int)


-- we also use an Actor to write our values to the tree
writeRandsTo :: RootNode -> Chan OutMessage -> Int -> Name -> Behavior_
writeRandsTo _    _   0 _    = Idle
writeRandsTo root out n name = ignoring $ do
    -- a random stream of ints:
    i <- randInt
    -- add them into the tree, returning a list of the results:
    b <- i `addValue` root
    -- report back input, result, and the name of this actor:
    send out (name,b,i)
    return $ writeRandsTo root out (n-1) name


