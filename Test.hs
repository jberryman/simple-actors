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

addValue :: Int -> RootNode -> IO Bool
addValue a nd = do
    v <- newEmptyMVar
    send nd (a,v)
    takeMVar v

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
    

-- TODO: TURN THIS INTO AN AUTOMATED TEST. ALSO MODIFY SO THAT ADDS ARE ACTUALLY
-- CONCURRENT:
binaryTreeTest = do
    -- create a new tree from an initial value
    root <- initTree 0
    -- a random stream of vlues (-100,100):
    str <- randomRs (-100,100) <$> getStdGen  
    -- add them into the tree, returning a list of the results:
    bs <- mapM (`addValue` root) $ take 100 str

    -- show:
    mapM (putStrLn . show) $ zip str bs


