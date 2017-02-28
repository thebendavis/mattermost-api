{-# LANGUAGE OverloadedStrings #-}
module Main (
  main
) where

import           Control.Exception

import           System.Exit

import           Text.Show.Pretty ( ppShow )

import           Data.Aeson
import qualified Data.HashMap.Strict as HM
import qualified Data.Sequence as Seq

import           Test.Tasty

import           Network.Mattermost
import           Network.Mattermost.WebSocket.Types
import           Network.Mattermost.Exceptions

import           Tests.Util
import           Tests.Types

main :: IO ()
main = defaultMain tests `catch` \(JSONDecodeException msg badJson) -> do
  putStrLn $ "JSONDecodeException: " ++ msg
  putStrLn badJson
  exitFailure

-- Users and other test configuration data

testConfig :: Config
testConfig = Config
  { configUsername = "testAdmin"
  , configEmail    = "testAdmin@example.com"
  , configHostname = "localhost"
  , configTeam     = "testteam"
  , configPort     = 8065
  , configPassword = "password"
  }

testUserLogin :: Login
testUserLogin = Login
  { username = "test-user"
  , password = "password"
  }

testMinChannel :: MinChannel
testMinChannel = MinChannel
  { minChannelName        = "test-channel"
  , minChannelDisplayName = "Test Channel"
  , minChannelPurpose     = Just "A channel for test cases"
  , minChannelHeader      = Just "Test Header"
  , minChannelType        = Ordinary
  }

testTeamsCreate :: TeamsCreate
testTeamsCreate = TeamsCreate
  { teamsCreateDisplayName = "Test Team"
  , teamsCreateName        = "testteam"
  , teamsCreateType        = Ordinary
  }

testAccount :: UsersCreate
testAccount =
    UsersCreate { usersCreateEmail          = "test-user@example.com"
                , usersCreatePassword       = password testUserLogin
                , usersCreateUsername       = username testUserLogin
                , usersCreateAllowMarketing = False
                }

-- Test groups

tests :: TestTree
tests = testGroup "Tests"
    [ setup
    , unitTests
    ]

-- Note that the order of the tests matters as each may have side
-- effects on which subsequent tests depend.
unitTests :: TestTree
unitTests = testGroup "Units"
    [ loginAsNormalUserTest
    , initialLoadTest
    , createChannelTest
    , getChannelsTest
    , leaveChannelTest
    , joinChannelTest
    ]

-- Test definitions

setup :: TestTree
setup = mmTestCase "Setup" testConfig $ do
  adminUser <- createAdminAccount

  print_ "Logging into Admin account"
  loginAdminAccount

  expectWSEvent "hello" (hasWSEventType WMHello)
  expectWSEvent "status" (hasWSEventType WMStatusChange &&&
                         wsHas (wepStatus . weData) (Just "online"))

  print_ "Creating test team"
  testTeam <- createTeam testTeamsCreate

  print_ "Getting Config"
  config <- getConfig
  print_ (ppShow config)

  print_ "Saving Config"
  -- Enable open team so that the admin can create
  -- new users.
  let Object oldConfig    = config
      Object teamSettings = oldConfig HM.! "TeamSettings"
      newConfig           = Object (HM.insert "TeamSettings"
                                   (Object (HM.insert "EnableOpenServer"
                                           (Bool True) teamSettings)) oldConfig)
  saveConfig newConfig

  expectWSEvent "join post"
    (hasWSEventType WMPosted &&&
     wsHas (\e -> postMessage <$> (wepPost $ weData e))
           (Just "testadmin has joined the channel."))

  print_ $ show adminUser

  expectWSEvent "new user"
    (hasWSEventType WMNewUser &&&
     wsHas weUserId (Just $ userId adminUser))

  print_ "Creating test account"
  testUser <- createAccount testAccount

  print_ "Add test user to test team"
  teamAddUser testTeam testUser

  expectWSEvent "user added"
    (hasWSEventType WMUserAdded &&&
     wsHas weUserId (Just $ userId testUser))

loginAsNormalUserTest :: TestTree
loginAsNormalUserTest = mmTestCase "Logging to normal account" testConfig $ do
  loginAccount testUserLogin

initialLoadTest :: TestTree
initialLoadTest = mmTestCase "Initial Load" testConfig $ do
  loginAccount testUserLogin
  initialLoad <- getInitialLoad
  expectWSEvent "hello" (hasWSEventType WMHello)
  -- print the team names
  print_ (ppShow (fmap teamName (initialLoadTeams initialLoad)))

createChannelTest :: TestTree
createChannelTest = mmTestCase "Create Channel" testConfig $ do
  loginAccount testUserLogin
  initialLoad <- getInitialLoad
  let team Seq.:< _ = Seq.viewl (initialLoadTeams initialLoad)
  chan <- createChannel team testMinChannel
  print_ (ppShow chan)

getChannelsTest :: TestTree
getChannelsTest = mmTestCase "Get Channels" testConfig $ do
  loginAccount testUserLogin
  initialLoad <- getInitialLoad
  let team Seq.:< _ = Seq.viewl (initialLoadTeams initialLoad)
  chans <- getChannels team

  let chan Seq.:< _ = Seq.viewl chans
  print_ (ppShow chan)

leaveChannelTest :: TestTree
leaveChannelTest = mmTestCase "Leave Channel" testConfig $ do
  loginAccount testUserLogin
  initialLoad <- getInitialLoad
  let team Seq.:< _ = Seq.viewl (initialLoadTeams initialLoad)
  chans <- getChannels team
  print_ (ppShow chans)

  let chan = findChannel chans $ minChannelName testMinChannel
  leaveChannel team chan

joinChannelTest :: TestTree
joinChannelTest = mmTestCase "Join Channel" testConfig $ do
  loginAccount testUserLogin
  initialLoad <- getInitialLoad

  let team Seq.:< _ = Seq.viewl (initialLoadTeams initialLoad)
  chans <- getMoreChannels team
  print_ (ppShow chans)

  let chan = findChannel chans $ minChannelName testMinChannel
  joinChannel team chan
