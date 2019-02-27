{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RecursiveDo #-}
module Database.Google.BigQuery.Types where

import Text.Printf
import Data.Aeson
import Data.Aeson.Types
import Data.Time.Clock
import Control.Monad.IO.Class
import Control.Monad.Fix
import Data.IORef
import Data.Maybe
import qualified Data.Map.Strict
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS


data DatasetReference = DatasetReference
  { _dsrefDatasetID :: T.Text
  , _dsrefProjectID :: T.Text
  } deriving (Eq, Show, Ord)

instance FromJSON DatasetReference where
  parseJSON (Object v) = DatasetReference
    <$> v .: "datasetId"
    <*> v .: "projectId"
  parseJSON invalid = typeMismatch "datasetReference" invalid

data Dataset = Dataset
  { _datasetKind :: T.Text
  , _datasetID :: T.Text
  , _datasetReference :: DatasetReference
  , _datasetLocation :: T.Text
  } deriving (Eq, Show, Ord)

instance FromJSON Dataset where
  parseJSON (Object v) = Dataset
    <$> v .: "kind"
    <*> v .: "id"
    <*> v .: "datasetReference"
    <*> v .: "location"
  parseJSON invalid = typeMismatch "dataset" invalid



class NamedKey a where
  keyName :: T.Text

instance NamedKey Dataset where keyName = "datasets"


data TableReference = TableReference
  { _tableReferenceProjectID :: T.Text
  , _tableReferenceDatasetID :: T.Text
  , _tableReferenceTableID   :: T.Text
  } deriving (Eq, Ord, Show)

instance FromJSON TableReference where
  parseJSON (Object v) = TableReference
    <$> v .: "projectId"
    <*> v .: "datasetId"
    <*> v .: "tableId"
  parseJSON invalid = typeMismatch "tableReference" invalid

-- | TableBasicInfo contains basic table info extracted from a table
-- | list.  It does not include the full schema, which is only available
-- | by getting a specific table.
data TableBasicInfo = TableBasicInfo
  { _tableKind         :: T.Text
  , _tableID           :: T.Text
  , _tableType         :: T.Text
  , _tableReference    :: TableReference
  , _tableFriendlyName :: Maybe T.Text
  } deriving (Eq, Ord, Show)

instance FromJSON TableBasicInfo where
  parseJSON (Object v) = TableBasicInfo
    <$> v .: "kind"
    <*> v .: "id"
    <*> v .: "type"
    <*> v .: "tableReference"
    <*> v .:? "friendlyName"
  parseJSON invalid = typeMismatch "tables" invalid

instance NamedKey TableBasicInfo where keyName = "tables"

-- | NB: Query parameters are currently unsupported when using legacy
-- | SQL mode.  The public API for generating queries is likely to
-- | change significantly as more features are added.
data Query = Query
  { _queryQuery          :: T.Text
  , _queryRowLimit       :: Maybe Int
  , _queryDefaultDataset :: Maybe DatasetReference
  , _queryTimeout        :: Maybe NominalDiffTime
  , _queryDryRun         :: Bool
  , _queryUseCache       :: Bool
  , _queryUseLegacySQL   :: Bool
  } deriving (Eq, Show)

class Paginated a b | a -> b where
  nextPageID :: a -> Maybe String
  getPage :: a -> [b]

data PaginatedResults a = PaginatedResults
  { _paginatedNextPageToken :: Maybe String
  , _paginatedValues :: [a]
  }

instance (FromJSON a, NamedKey a) => FromJSON (PaginatedResults a) where
    parseJSON (Object v) = PaginatedResults
      <$> v .:? "nextPageToken"
      <*> v .:  keyName @a
    parseJSON invalid = typeMismatch "paginated_results" invalid

instance Paginated (PaginatedResults a) a where
  nextPageID = _paginatedNextPageToken
  getPage = _paginatedValues

data PageIter carryType urlType = Done carryType
                                | Iter carryType urlType

withPages'
  :: (Monad m, MonadIO m, Paginated a b) =>
  (String -> String) -> (String -> m a) -> PageIter (m [c]) String -> (b -> m c) -> m [c]
withPages' _ _ (Done carry) _ = carry
withPages' normalizeURL fetchPage  (Iter carry thisURL) pageAction = do
  liftIO . putStrLn $ printf "getting URL: %s" thisURL
  p <- fetchPage thisURL
  let pageData = getPage p
  pageActions <- mapM pageAction pageData
  let pa = (pageActions <>) <$> carry
  let nextURL = nextPageID p
  case nextURL of
    Nothing -> withPages' normalizeURL fetchPage (Done pa) pageAction
    Just u' ->
      let uNorm = normalizeURL u' in
      withPages' normalizeURL fetchPage (Iter pa uNorm) pageAction

withPage' ::
  (Monad m, MonadIO m, MonadFix m, Paginated a b) =>
  (String -> String) -> (String -> m a) -> (b -> m c) -> PageIter [c] String -> m (PageIter [c] string)
withPage' cURL fetchPage pageAction = mfix $ \p -> withPage''
  where
    withPage'' p = do
      case p of
        Done c -> return $ Done c
        Iter c u -> do
          liftIO . putStrLn $ printf "getting url: %s" u
          p <- fetchPage u
          let pData = getPage p
          let u = cURL <$> nextPageID p
          a <- mapM pageAction pData
          let a' = a <> c
          case u of
            Nothing -> return $ Done a'
            Just u' -> withPage'' (Iter a' u')

withPage :: (Monad m, MonadIO m, MonadFix m, Paginated a b) =>
  String -> (String -> String) -> (String -> m a) -> (b -> m c) -> m [c]
withPage baseURL normalizeURL fetchPage act = do
  result <- withPage' normalizeURL fetchPage act  $ Iter [] baseURL
  case result of
    Done c -> return c
    _ -> liftIO (putStrLn "error") >> return []

data AddressablePage = AddressablePage
  { _baseURL :: String
  , _offsetPart :: Maybe String
  , _mkURL :: String -> Maybe String -> String
  }

instance Show AddressablePage where
  show (AddressablePage base offset _) =
    printf "base: %s; offset: %s" base (fromMaybe "<Nothing>" offset)


data FixI a = DoneI [a] | IterI String (FixI a)
fromDone :: FixI a -> [a]
fromDone (DoneI as) = as

fixPages' :: (Monad m, MonadIO m, MonadFix m, Paginated a b) =>
  String -> (String -> String -> String) -> (String -> m a) -> a -> m [b]
fixPages' baseURL nextURL pageGetter =
  \page -> mdo
    liftIO $ putStrLn "parsing page..."
    let contents = otherContents <> getPage page
    let u' = nextURL baseURL <$> nextPageID page
    otherContents <- case u' of
                       Nothing -> pure []
                       Just addr -> do
                         nPage <- pageGetter addr
                         fixPages' baseURL nextURL pageGetter nPage

    return contents

fixPages ::
  (Monad m, MonadIO m, MonadFix m, Paginated a b) =>
  String -> (String -> String -> String) -> (String -> m a) -> m [b]
fixPages u nxt act =
  act u >>= fixPages' u nxt act

getAllPages ::
  (Monad m, MonadFix m, MonadIO m, Paginated a b) =>
  String -> (String -> String) -> (String -> m a) -> m [b]
getAllPages baseURL nextURL fetchPage =
  withPage baseURL nextURL fetchPage return
