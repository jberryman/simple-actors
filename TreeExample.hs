module Main
    where

import Control.Concurrent.Actors
import Control.Applicative
import Control.Concurrent.MVar


{- 
 - We build a sort of living binary tree or dynamic sorting network from Actors.
 - The formulation is not too different from what we would get using flat data
 - types
 -}


-- the actor equivalent of a Nil leaf node:
nil :: Behavior Operation
nil = Receive $ do
    (Query _ var) <- received 
    send var False -- signal Int is not present in tree
    return nil     -- await next message

   <|> do          -- else, Insert received
    l <- spawn nil -- spawn child nodes
    r <- spawn nil
    branch l r . val <$> received  -- create branch from inserted val
    
-- a branch node with a value 'v' and two children
branch :: Node -> Node -> Int -> Behavior Operation    
branch l r v = loop where
    loop = Receive $ do
        m <- received 
        case compare (val m) v of
             LT -> send l m
             GT -> send r m
             EQ -> case m of -- signal Int present in tree:
                        (Query _ var) -> send var True
                        _             -> return ()
        return loop


type Node = Mailbox Operation

-- operations supported by the network:
data Operation = Insert { val :: Int }
               | Query { val :: Int
                       , sigVar :: MVar Bool }

insert :: Node -> Int -> IO ()
insert t = send t . Insert

-- MVar is in the 'SplitChan' class so actors can 'send' to it:
query :: Node -> Int -> IO Bool
query t a = do
    v <- newEmptyMVar
    send t (Query a v)
    takeMVar v


---- TEST CODE: ----

main = do
    t <- spawn nil
    mapM_ (insert t) [5,3,7,2,4,6,8]
    mapM (query t) [1,5,0,7] >>= print

    
{-    


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
    -- all output by forked actors is printed by this actor:
    v <- newEmptyMVar
    output <- spawn $ 
        putStrB (26*1000) `mappend` signalB v
      --printB (26*1000) `mappend` signalB v
    -- create a new tree from an initial value
    root <- initTree 0
    -- fork 26 actors writing random vals to tree:
    mapM_ (spawn_ . writeRandsTo root output 1000) ['a'..'z']
    -- exit when threads finish
    takeMVar v
    

-- Lift an RNG to an Action. A non-abstraction-breaking use of liftIO here, IMHO
randInt :: Action a Int
randInt = liftIO $ randomRIO (-5000,5000) 


type Name = Char
type OutMessage = String
--type OutMessage = (Name,Bool,Int)

-- we also use an Actor to write our values to the tree
writeRandsTo :: RootNode -> Mailbox OutMessage -> Int -> Name -> Behavior a
writeRandsTo root out n name = Behavior $ do
    guard (n /= 0)
    -- a random stream of ints:
    i <- randInt
    -- add them into the tree, returning a list of the results:
    b <- i `addValue` root
    -- report back input, result, and the name of this actor:
    send out $ if b then "X" else "."
  --send out (name,b,i)
    return $ writeRandsTo root out (n-1) name

-}
