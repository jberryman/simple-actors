module Main
    where

import Criterion.Main
import Debug.Trace
import Control.DeepSeq
--import Criterion.Types
--import Criterion.Config
import System.Random

import qualified Data.Set as S
import Control.Concurrent.Actors
import Control.Concurrent.Chan.Split
import TreeExample


-- THIS IS A WORK-IN-PROGRESS. PLEASE IGNORE. --


{- NOTES & IDEAS

look again at simple case expr for nil
look at eventlog with equal number inserts and queries (are queries very slow?)
look at bottom of heap profile, halfway through. Get that flat.
what about using forkOnIO to keep child actors on the same OS thread?
better way to handle recursion in Behavior?
unpacking MVars?


 -}
-- put benchmarking & optimizing on hold until we can figure out how to get
-- consistent results....

main0 = defaultMain [
    bench "calibrate" $ whnf sqrt (999999999 :: Double)
    -- bgroup "actors" [
    --         bench "insert 1000, query 1000" $ whnfIO $ testActors (2^10 - 1, 1000)
    --       , bench "insert 1000, query 100000" $ whnfIO $ testActors (2^10 - 1, 100000)
    --       -- , bench "insert 100000, query 100000" $ whnfIO $ testActors (2^17 - 1,100000)
    --     ]
  -- , -- compare with Set, for a benchmark:
  --   bgroup "intmap" [
  --           bench "insert 1000, query 1000" $ whnfIO $ testSet (1000,1000)
  --         , bench "insert 1000, query 100000" $ whnfIO $ testSet (1000,100000)
  --         , bench "insert 100000, query 100000" $ whnfIO $ testSet (100000,100000)
  --       ]
    ]

main :: IO ()
main = testActors (2^10 - 1, 1000) >>= print

-- DEBUGGING:
seed :: Int
seed = 2876549687276

-- SET
testSet :: (Int,Int)  -- (size of tree, number of queries)
        -> IO Int -- number of Ints present 
testSet (x,y) = do
    let s = S.fromList $ friendlyList x

    --g <- getStdGen  
    let g = mkStdGen seed

    -- we'll take our random queries such that about half are misses:
    let is = take y $ randomRs (1, x*2) g :: [Int]
        results = map (\i-> (i, S.member i s)) is
        -- evaled to whnf so all work is done:
        payload = length $ filter snd results
    return payload

-- silly, so we can get a better picture of what our simple-actors code is doing:
deepEvaluate :: (NFData a, Monad m)=> a -> m a
deepEvaluate a = a `deepseq` return a

-- ACTORS
testActors :: (Int,Int) -> IO Int
testActors (x,y) = do
    traceEventIO "creating friendlyList"
    fl <- deepEvaluate $ friendlyList x

    traceEventIO "inserting numbers into tree"
    t <- spawn nil
    mapM_ (insert t) fl

    traceEventIO "generate random values"
    --g <- getStdGen  
    let g = mkStdGen seed
    is <- deepEvaluate (take y $ randomRs (1, x*2) g :: [Int])

    traceEventIO "query random values and calculate payload"
    results <- getChanContents =<< streamQueries t is
    
    let payload = length $ filter snd $ take y results
    return payload

-- create a list 1..n, ordered such that we get a mostly-balanced tree when
-- inserted sequentially:
friendlyList :: Int -> [Int]
friendlyList n = fromSorted [1..n]

-- lists of length 2^x - 1 will result in perfectly-balanced trees
fromSorted :: [a] -> [a]
fromSorted = foldl mkList [] . divide 1
    where mkList l (n:ns) = n : l ++ fromSorted ns
          mkList _ [] = error "how can that be?!"
          divide _ [] = []
          divide c xs = take c xs : divide (c*2) (drop c xs)
