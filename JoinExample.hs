module JoinExample
    where

import Control.Concurrent.Actors
import Control.Concurrent.Chan.Split

sumTuple :: (SplitChan c x)=> c Int -> Behavior (Int,(Int,Int))
sumTuple c = Receive $ do
    (x,(y,z)) <- received
    send (out c) (x+y+z)
    return $ sumTuple c

-- try making instance Sources Mailbox, instead be for SplitChan?
-- look at what we did to get nice defaulting for zippo
-- make send only work on Mailbox, add function out :: (SplitChan c x)=> c a -> Mailbox a

main = do
    (i,o) <- newSplitChan
    sms <- getChanContents o
    -- spawn, returning joined tupboxes:
    (b1,bTuple) <- spawn $ sumTuple i  
    
    mapM_ (send bTuple) [(3,1),(2,2),(1,3),(0,4)]
    mapM_ (send b1) [1..4]

    print $ [5,6,7,8] == (take 4 sms)

    -- nested join:
    (b1',(b2',b3')) <- spawn $ sumTuple i  
    mapM_ (send b3') [1..4]
    mapM_ (send b2') [3,2,1,0]
    -- spawn actor that starts immediately:
    let beh n = Receive $ send b1' n >> return (beh $ n+1)
    () <- spawn (beh 1)

    print $ [5,6,7,8] == (take 4 sms)
