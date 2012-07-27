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


myConfig = defaultConfig { cfgPerformGC = ljust True }

main = defaultMainWith myConfig (return ()) [
    bgroup "actors" [
            bench "insert 1000, query 1000" $ whnfIO $ testActors (2^10 - 1, 1000)
          , bench "insert 1000, query 100000" $ whnfIO $ testActors (2^10 - 1, 100000)
          , bench "insert 100000, query 100000" $ whnfIO $ testActors (2^17 - 1,100000)
        ]
  -- , -- compare with Set, for a benchmark:
  --   bgroup "intmap" [
  --           bench "insert 1000, query 1000" $ whnfIO $ testSet (1000,1000)
  --         , bench "insert 1000, query 100000" $ whnfIO $ testSet (1000,100000)
  --         , bench "insert 100000, query 100000" $ whnfIO $ testSet (100000,100000)
  --       ]
    ]

{-  === ACTOR BENCHMARKS ===                                             === AND THE SET VERSIONS, FWIW: ===
 -
benchmarking actors/insert 1000, query 1000                              benchmarking intmap/insert 1000, query 1000                                                                                          
collecting 100 samples, 1 iterations each, in estimated 10.42159 s       collecting 100 samples, 6 iterations each, in estimated 14.73683 s
mean: 122.2085 ms, lb 119.1732 ms, ub 126.2098 ms, ci 0.950              mean: 28.63115 ms, lb 26.34421 ms, ub 31.98199 ms, ci 0.950
std dev: 17.69682 ms, lb 14.05787 ms, ub 24.21683 ms, ci 0.950           std dev: 13.97599 ms, lb 10.59677 ms, ub 19.47218 ms, ci 0.950
found 4 outliers among 100 samples (4.0%)                                found 9 outliers among 100 samples (9.0%)
  3 (3.0%) high mild                                                       6 (6.0%) high mild
  1 (1.0%) high severe                                                     3 (3.0%) high severe
variance introduced by outliers: 89.396%                                 variance introduced by outliers: 98.936%
variance is severely inflated by outliers                                variance is severely inflated by outliers
                                                                         

benchmarking actors/insert 1000, query 100000                            benchmarking intmap/insert 1000, query 100000
collecting 100 samples, 1 iterations each, in estimated 974.7428 s       collecting 100 samples, 1 iterations each, in estimated 152.5550 s
mean: 9.642770 s, lb 9.512721 s, ub 9.754924 s, ci 0.950                 mean: 1.367143 s, lb 1.342096 s, ub 1.412953 s, ci 0.950
std dev: 607.6121 ms, lb 424.9625 ms, ub 969.9744 ms, ci 0.950           std dev: 169.1700 ms, lb 102.6455 ms, ub 275.0464 ms, ci 0.950
found 8 outliers among 100 samples (8.0%)                                found 8 outliers among 100 samples (8.0%)
  1 (1.0%) low severe                                                      5 (5.0%) high mild
  3 (3.0%) high mild                                                       3 (3.0%) high severe
  4 (4.0%) high severe                                                   variance introduced by outliers: 85.245%
variance introduced by outliers: 59.536%                                 variance is severely inflated by outliers
variance is severely inflated by outliers                                


benchmarking actors/insert 100000, query 100000                          benchmarking intmap/insert 100000, query 100000
collecting 100 samples, 1 iterations each, in estimated 16001.50 s       collecting 100 samples, 1 iterations each, in estimated 374.3902 s
mean: 61.39105 s, lb 56.39700 s, ub 66.18949 s, ci 0.950                 mean: 3.898701 s, lb 3.833580 s, ub 3.975744 s, ci 0.950
std dev: 25.20601 s, lb 22.88689 s, ub 28.01352 s, ci 0.950              std dev: 362.5431 ms, lb 308.7098 ms, ub 443.8427 ms, ci 0.950
variance introduced by outliers: 98.909%                                 found 2 outliers among 100 samples (2.0%)
variance is severely inflated by outliers                                  2 (2.0%) high mild
                                                                         variance introduced by outliers: 76.901%
                                                                         variance is severely inflated by outliers
-}


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
