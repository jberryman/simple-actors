module Main
    where

import Control.Concurrent.Actors
import Control.Applicative
import Control.Concurrent.MVar

import Control.Concurrent.Chan.Split
import Control.Concurrent.Chan.Class
import Control.Concurrent(forkIO)


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
   
   <|> do          -- else, StreamQuery received
    (StreamQuery v var) <- received 
    send var (v,False) 
    return nil     

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
                        (StreamQuery _ var) -> send var (v, True)
                        _ -> return ()
        return loop


type Node = Mailbox Operation

-- operations supported by the network:
data Operation = Insert { val :: Int }
               | Query { val :: Int
                       , sigVar :: MVar Bool }
               -- variant that sends query result out through a Chan:
               | StreamQuery { val :: Int
                             , sigChan :: InChan (Int, Bool) }

insert :: Node -> Int -> IO ()
insert t = send t . Insert

-- MVar is in the 'SplitChan' class so actors can 'send' to it:
query :: Node -> Int -> IO Bool
query t a = do
    v <- newEmptyMVar
    send t (Query a v)
    takeMVar v

-- fork a process that does a bunch of queries, streaming the results back to returned Chan:
streamQueries :: Node -> [Int] -> IO (OutChan (Int,Bool))
streamQueries t as = do
    (i,o) <- newSplitChan
    forkIO $ mapM_ (send t . flip StreamQuery i) as
    return o

---- TEST CODE: ----

main = do
    t <- spawn nil
    mapM_ (insert t) [5,3,7,2,4,6,8]
    mapM (query t) [1,5,0,7] >>= print

mainStream = do
    t <- spawn nil
    mapM_ (insert t) [5,3,7,2,4,6,8]
    resps <- getChanContents =<< streamQueries t [1,5,0,7]
    print $ take 4 resps 

