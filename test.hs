{-# LANGUAGE CPP
           , NoImplicitPrelude
           , UnicodeSyntax
           , DeriveDataTypeable
 #-}

#if MIN_VERSION_base(4,3,0)
{-# OPTIONS_GHC -fno-warn-warnings-deprecations #-} -- For block and unblock
#endif

module Main where

--------------------------------------------------------------------------------
-- Imports
--------------------------------------------------------------------------------

-- from base:
import Control.Concurrent ( ThreadId, threadDelay, throwTo, killThread )
import Control.Exception  ( Exception, fromException
                          , AsyncException(ThreadKilled)
                          , throwIO
                          , unblock, block, blocked
                          )
import Control.Monad      ( return, (>>=), replicateM_ )

#if __GLASGOW_HASKELL__ < 701
import Control.Monad      ( (>>), fail )
#endif

import Data.Bool          ( Bool(False, True), not )
import Data.Eq            ( Eq )
import Data.Either        ( either )
import Data.Function      ( ($), id, const, flip )
import Data.Functor       ( Functor(fmap), (<$>) )
import Data.Int           ( Int )
import Data.Maybe         ( Maybe, maybe )
import Data.IORef         ( newIORef, readIORef, writeIORef )
import Data.Typeable      ( Typeable )
import Prelude            ( fromInteger )
import System.Timeout     ( timeout )
import System.IO          ( IO )
import Text.Show          ( Show )

-- from base-unicode-symbols:
import Data.Eq.Unicode       ( (≡) )
import Prelude.Unicode       ( (⋅) )
import Data.Function.Unicode ( (∘) )

-- from concurrent-extra:
import qualified Control.Concurrent.Lock as Lock

-- from stm:
import Control.Concurrent.STM ( atomically )

-- from HUnit:
import Test.HUnit ( Assertion, assert )

-- from test-framework:
import Test.Framework ( Test, defaultMain, testGroup )

-- from test-framework-hunit:
import Test.Framework.Providers.HUnit ( testCase )

-- from threads:
import Control.Concurrent.Thread       ( Result, result )
import Control.Concurrent.Thread.Group ( ThreadGroup )

import qualified Control.Concurrent.Thread       as Thread
import qualified Control.Concurrent.Thread.Group as ThreadGroup


--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

main ∷ IO ()
main = defaultMain tests

tests ∷ [Test]
tests = [ testGroup "Thread" $
          [ testGroup "forkIO" $
            [ testCase "wait"            $ test_wait            Thread.forkIO
            , testCase "blockedState"    $ test_blockedState    Thread.forkIO
            , testCase "unblockedState"  $ test_unblockedState  Thread.forkIO
            , testCase "sync exception"  $ test_sync_exception  Thread.forkIO
            , testCase "async exception" $ test_async_exception Thread.forkIO
            ]
          , testGroup "forkOS" $
            [ testCase "wait"            $ test_wait            Thread.forkOS
            , testCase "blockedState"    $ test_blockedState    Thread.forkOS
            , testCase "unblockedState"  $ test_unblockedState  Thread.forkOS
            , testCase "sync exception"  $ test_sync_exception  Thread.forkOS
            , testCase "async exception" $ test_async_exception Thread.forkOS
            ]
#ifdef __GLASGOW_HASKELL__
          , testGroup "forkOnIO 0" $
            [ testCase "wait"            $ test_wait            (Thread.forkOnIO 0)
            , testCase "blockedState"    $ test_blockedState    (Thread.forkOnIO 0)
            , testCase "unblockedState"  $ test_unblockedState  (Thread.forkOnIO 0)
            , testCase "sync exception"  $ test_sync_exception  (Thread.forkOnIO 0)
            , testCase "async exception" $ test_async_exception (Thread.forkOnIO 0)
            ]
#if MIN_VERSION_base(4,3,0)
          , testGroup "forkIOUnmasked" $
            [ testCase "wait"            $ test_wait            (Thread.forkIOUnmasked)
            , testCase "unblockedState'" $ test_unblockedState' (Thread.forkIOUnmasked)
            , testCase "sync exception"  $ test_sync_exception  (Thread.forkIOUnmasked)
            , testCase "async exception" $ test_async_exception (Thread.forkIOUnmasked)
            ]
#endif
#endif
          ]
        , testGroup "ThreadGroup" $
          [ testGroup "forkIO" $
            [ testCase "wait"              $ wrapIO test_wait
            , testCase "blockedState"      $ wrapIO test_blockedState
            , testCase "unblockedState"    $ wrapIO test_unblockedState
            , testCase "sync exception"    $ wrapIO test_sync_exception
            , testCase "async exception"   $ wrapIO test_async_exception

            , testCase "group single wait" $ test_group_single_wait ThreadGroup.forkIO
            , testCase "group nrOfRunning" $ test_group_nrOfRunning ThreadGroup.forkIO
            ]
          , testGroup "forkOS" $
            [ testCase "wait"              $ wrapOS test_wait
            , testCase "blockedState"      $ wrapOS test_blockedState
            , testCase "unblockedState"    $ wrapOS test_unblockedState
            , testCase "sync exception"    $ wrapOS test_sync_exception
            , testCase "async exception"   $ wrapOS test_async_exception

            , testCase "group single wait" $ test_group_single_wait ThreadGroup.forkOS
            , testCase "group nrOfRunning" $ test_group_nrOfRunning ThreadGroup.forkOS
            ]
#ifdef __GLASGOW_HASKELL__
          , testGroup "forkOnIO 0" $
            [ testCase "wait"              $ wrapOnIO_0 test_wait
            , testCase "blockedState"      $ wrapOnIO_0 test_blockedState
            , testCase "unblockedState"    $ wrapOnIO_0 test_unblockedState
            , testCase "sync exception"    $ wrapOnIO_0 test_sync_exception
            , testCase "async exception"   $ wrapOnIO_0 test_async_exception

            , testCase "group single wait" $ test_group_single_wait (ThreadGroup.forkOnIO 0)
            , testCase "group nrOfRunning" $ test_group_nrOfRunning (ThreadGroup.forkOnIO 0)
            ]
#if MIN_VERSION_base(4,3,0)
          , testGroup "forkIOUnmasked" $
            [ testCase "wait"              $ wrapIOUnmasked test_wait
            , testCase "unblockedState'"   $ wrapIOUnmasked test_unblockedState'
            , testCase "sync exception"    $ wrapIOUnmasked test_sync_exception
            , testCase "async exception"   $ wrapIOUnmasked test_async_exception

            , testCase "group single wait" $ test_group_single_wait ThreadGroup.forkIOUnmasked
            , testCase "group nrOfRunning" $ test_group_nrOfRunning ThreadGroup.forkIOUnmasked
            ]
#endif
#endif
          ]
        ]

-- Exactly 1 moment. Currently equal to 0.005 seconds.
a_moment ∷ Int
a_moment = 5000


--------------------------------------------------------------------------------
-- General properties
--------------------------------------------------------------------------------

type Fork α = IO α → IO (ThreadId, IO (Result α))

test_wait ∷ Fork () → Assertion
test_wait fork = assert $ fmap isJustTrue $ timeout (10 ⋅ a_moment) $ do
  r ← newIORef False
  (_, wait) ← fork $ do
    threadDelay $ 2 ⋅ a_moment
    writeIORef r True
  _ ← wait
  readIORef r

test_blockedState ∷ Fork Bool → Assertion
test_blockedState fork = do (_, wait) ← block $ fork $ blocked
                            wait >>= result >>= assert

test_unblockedState ∷ Fork Bool → Assertion
test_unblockedState fork = do (_, wait) ← unblock $ fork $ not <$> blocked
                              wait >>= result >>= assert

test_unblockedState' ∷ Fork Bool → Assertion
test_unblockedState' fork = do (_, wait) ← block $ fork $ not <$> blocked
                               wait >>= result >>= assert

test_sync_exception ∷ Fork () → Assertion
test_sync_exception fork = assert $ do
  (_, wait) ← fork $ throwIO MyException
  waitForException MyException wait

waitForException ∷ (Exception e, Eq e) ⇒ e → IO (Result α) → IO Bool
waitForException e wait = wait <$$> either (justEq e ∘ fromException)
                                           (const False)

test_async_exception ∷ Fork () → Assertion
test_async_exception fork = assert $ do
  l ← Lock.newAcquired
  (tid, wait) ← fork $ Lock.acquire l
  throwTo tid MyException
  waitForException MyException wait

data MyException = MyException deriving (Show, Eq, Typeable)
instance Exception MyException

test_killThread ∷ Fork () → Assertion
test_killThread fork = assert $ do
  l ← Lock.newAcquired
  (tid, wait) ← fork $ Lock.acquire l
  killThread tid
  waitForException ThreadKilled wait


--------------------------------------------------------------------------------
-- ThreadGroup
--------------------------------------------------------------------------------

wrapIO ∷ (Fork α → IO β) → IO β
wrapIO = wrap ThreadGroup.forkIO

wrapOS ∷ (Fork α → IO β) → IO β
wrapOS = wrap ThreadGroup.forkOS

#ifdef __GLASGOW_HASKELL__
wrapOnIO_0 ∷ (Fork α → IO β) → IO β
wrapOnIO_0 = wrap $ ThreadGroup.forkOnIO 0

#if MIN_VERSION_base(4,3,0)
wrapIOUnmasked ∷ (Fork α → IO β) → IO β
wrapIOUnmasked = wrap ThreadGroup.forkIOUnmasked
#endif
#endif

wrap ∷ (ThreadGroup → Fork α) → (Fork α → IO β) → IO β
wrap doFork test = ThreadGroup.new >>= test ∘ doFork

test_group_single_wait ∷ (ThreadGroup → Fork ()) → Assertion
test_group_single_wait doFork = assert $ fmap isJustTrue $ timeout (10 ⋅ a_moment) $ do
  tg ← ThreadGroup.new
  r ← newIORef False
  _ ← doFork tg $ do
    threadDelay $ 2 ⋅ a_moment
    writeIORef r True
  _ ← ThreadGroup.wait tg
  readIORef r

test_group_nrOfRunning ∷ (ThreadGroup → Fork ()) → Assertion
test_group_nrOfRunning doFork = assert $ fmap isJustTrue $ timeout (10 ⋅ a_moment) $ do
  tg ← ThreadGroup.new
  l ← Lock.newAcquired
  replicateM_ (fromInteger n) $ doFork tg $ Lock.acquire l
  true ← fmap (≡ n) $ atomically $ ThreadGroup.nrOfRunning tg
  Lock.release l
  return true
    where
      -- Don't set this number too big otherwise forkOS might throw an exception
      -- indicating that too many OS threads have been created:
      n = 100


--------------------------------------------------------------------------------
-- Utils
--------------------------------------------------------------------------------

-- | Check if the given value equals 'Just' 'True'.
isJustTrue ∷ Maybe Bool → Bool
isJustTrue = maybe False id

-- | Check if the given value in the 'Maybe' equals the given reference value.
justEq ∷ Eq α ⇒ α → Maybe α → Bool
justEq = maybe False ∘ (≡)

-- | A flipped '<$>'.
(<$$>) ∷ Functor f ⇒ f α → (α → β) → f β
(<$$>) = flip (<$>)


-- The End ---------------------------------------------------------------------
