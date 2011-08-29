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
    a `doing` (behavior $ sendInputTo output 200)
    -- these will block 
    a `doing` (behavior $ sendInputTo output 200)
    a `doing` (behavior $ sendInputTo output 200)
    a `doing` (behavior $ sendInputTo output 200)
    a `doing` (behavior $ sendInputTo output 200)

     -- output should be in order because actor forks waited their turns above:
    getChanContents output >>=
        putStrLn . unwords . map show . take 1000

    putStrLn "DONE!"

-- TODO: consider if we should export a BehaviorStep type synonym. Alternatively
-- we might do: UnwrappedBehavior, or something to that effect
sendInputTo :: Chan Int -> Int -> (Int -> Action (Behavior Int))
sendInputTo c n i = do
    send c i
    -- TODO: Consider defining:
    -- elseReturn b a = if b then done else return a
    -- actually something named like guard would be better:
    if n == 1 
        then done
        -- TODO: THIS IS ALSO PRETTY CLUNKY:
        --  perhaps define
        --      continue = return . behavior
        --      continue_ = return . behavior_
        else return $ behavior $ sendInputTo c (n-1)

senderTo :: Int -> Mailbox Int -> Behavior_
senderTo n c = behavior_ $ do
    send c n
    if n == 1
        then done
        else return $ senderTo (n-1) c


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
    m <- forkActorDoing $ treeNode
    undefined


treeNode = undefined

