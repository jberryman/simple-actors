module Main
    where

import Criterion.Config
import Criterion.Main
import Criterion.Types
import System.Random

import qualified Data.Set as S
import Control.Concurrent.Actors
import Control.Concurrent.Chan.Split
import TreeExample

-- put benchmarking & optimizing on hold until we can figure out how to get
-- consistent results....

main0 = defaultMain [
    bench "calibrate" $ whnf sqrt 999999999
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

main = testActors (2^10 - 1, 1000) >>= print

-- DEBUGGING:
seed = 2876549687276 :: Int

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

-- ACTORS
testActors :: (Int,Int) -> IO Int
testActors (x,y) = do
    t <- spawn nil
    mapM_ (insert t) $ friendlyList x
    --g <- getStdGen  
    let g = mkStdGen seed

    let is = take y $ randomRs (1, x*2) g :: [Int]
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
          divide _ [] = []
          divide c xs = take c xs : divide (c*2) (drop c xs)
