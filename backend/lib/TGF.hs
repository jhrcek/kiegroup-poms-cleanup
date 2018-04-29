{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module TGF
  ( parseDeps
  , parseTGF
  , Tree
  , TGF
  , nodeDeclarations
  , NodeId
  , Dependency
  , Coordinate
  , depNames
  , depTree
  , Deps
  , cGroupId
  , cArtifactId
  , cPackaging
  , cQualifier
  , cVersion
  , dScope
  , dOptional
  , dCoordinate
  , equalByGroupAndArtifact
  , mkCoord
  , extractRootCoordinate
  , toDeps
  ) where

import Data.Aeson
import Data.Attoparsec.Text (Parser, char, decimal, endOfInput, endOfLine, isEndOfLine, parseOnly, sepBy, skipMany, space, takeTill)
import Data.Char (isDigit)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (mapMaybe)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as Txt
import Data.Tree
import Filesystem.Path (FilePath)
import Prelude hiding (FilePath)
import Util (filepathToText)

-- Generic TGF parsing

type NodeId = Int
type NodeData = (NodeId, Text)
type EdgeData = (NodeId, NodeId, Text)


data TGF = TGF
  { nodeDeclarations :: [NodeData]
  , edgeDeclarations :: [EdgeData]
  } deriving Show


parseTGF :: Text -> Either String TGF
parseTGF = parseOnly tgfP


tgfP :: Parser TGF
tgfP = TGF
    <$> (nodeDeclP `sepBy` endOfLine) <* (endOfLine >> char '#' >> endOfLine)
    <*> (edgeDeclP `sepBy` endOfLine) <* (skipMany space >> endOfInput)


nodeDeclP :: Parser NodeData
nodeDeclP = (,)
    <$> decimal <* space
    <*> takeTill isEndOfLine


edgeDeclP :: Parser EdgeData
edgeDeclP = (,,)
    <$> decimal <* space
    <*> decimal <* space
    <*> takeTill isEndOfLine


-- Stuff specific to TGF files generated by mvn dependency:analyze -DoutputType=tfg
-- Assuming those files always contain valid trees


{-| Represents all data from a single .tgf file produced by mvn dependency:analyze -DoutputType=tfg-}
data Deps = Deps
    { depNames :: IntMap Dependency
    , depTree  :: Tree NodeId
    } deriving Show


parseDeps :: Text -> Either String Deps
parseDeps tgfSource = parseTGF tgfSource >>= toDeps


toDeps :: TGF -> Either String Deps
toDeps tgf =
  let eitherErrorOrListOfDeps = mapM (\(nid, depText) -> (nid,) <$> readDependency depText) $ nodeDeclarations tgf
  in case eitherErrorOrListOfDeps of
        Right listOfDeps -> Right Deps{depNames = IntMap.fromList listOfDeps, depTree = toTree tgf}
        Left err         -> Left err


{-| Represents data contained in " org.apache.xmlbeans:xmlbeans:jar:2.6.0:compile" -}
data Dependency = Dependency
    { dCoordinate :: Coordinate
    , dScope      :: Text
    , dOptional   :: Bool
    } deriving (Eq, Ord)


instance Show Dependency where
    show (Dependency coord scope opt) =
        show coord ++ ":" ++ Txt.unpack scope ++ if opt then " (optional)" else ""

{-| Maven Coordinates as described in https://maven.apache.org/pom.html#Maven_Coordinates -}
data Coordinate = Coordinate
    { cGroupId    :: Text
    , cArtifactId :: Text
    , cPackaging  :: Text
    , cQualifier  :: Maybe Text
    , cVersion    :: Text
    } deriving (Eq, Ord)

instance ToJSON Coordinate where
    toJSON (Coordinate groupId artifactId packaging _qualifier version) =
        object [ "grp" .= groupId
               , "art" .= artifactId
               , "pkg" .= packaging
               , "ver" .= version
               ]

instance Show Coordinate where
    show (Coordinate grp art pac mayQualifier ver) =
        Txt.unpack $ Txt.intercalate ":" fields
      where
        fields = case mayQualifier of
            Just qual -> [grp, art, pac, qual, ver]
            Nothing   -> [grp, art, pac,       ver]


mkCoord :: Text -> Text -> Text -> Text -> Coordinate
mkCoord grp art pac = Coordinate grp art pac Nothing


equalByGroupAndArtifact :: Dependency -> Dependency -> Bool
equalByGroupAndArtifact d1 d2 =
  let c1 = dCoordinate d1
      c2 = dCoordinate d2
  in cGroupId c1 == cGroupId c2 && cArtifactId c1 == cArtifactId c2

readCoordinate :: Text -> Either String Coordinate
readCoordinate = fmap dCoordinate . readDependency

readDependency :: Text -> Either String Dependency
readDependency txt =
    let dep = case Txt.splitOn ":" txt of
              [group,artifact,packaging,qualifier,version,scope] ->
                  Right $ Dependency (Coordinate group artifact packaging (Just qualifier) version) sc opt where (sc,opt) = parseScope scope
              [group,artifact,packaging,version,scope]           ->
                  Right $ Dependency (Coordinate group artifact packaging Nothing          version) sc opt where (sc,opt) = parseScope scope
              [group,artifact,packaging,version]                 ->
                  Right $ Dependency (Coordinate group artifact packaging Nothing          version) "compile" False
              _                                                  ->
                  Left $ "Unexpected dependency format: " ++ Txt.unpack txt
        validateVersion d = let ver = cVersion $ dCoordinate d
                            in if any isDigit (Txt.unpack ver) || ver == "jdk"
                                   then return d
                                   else Left $ "I was expecting verision to contain at least one digit in " ++ show d
        validatePackaging d = if cPackaging (dCoordinate d) `elem` knownPackagings
                               then return d
                               else Left $ "Urecognized dependency packaging in " ++ show d
        validateScope d = if dScope d `elem` knownScopes
                           then return d
                           else Left $ "Unrecognized scope in " ++ show d
    in dep >>= validateVersion >>= validatePackaging >>= validateScope

parseScope :: Text -> (Text, Bool)
parseScope scopeMaybeWithOptional = case Txt.words scopeMaybeWithOptional of
    [scope, "(optional)"] -> (scope, True)
    [scope]               -> (scope, False)
    _                     -> error $ "Unrecognized scrope " ++ show scopeMaybeWithOptional

knownPackagings :: [Text]
knownPackagings =
    ["bundle"
    ,"eclipse-feature"
    ,"eclipse-plugin"
    ,"eclipse-repository"
    ,"eclipse-test-plugin"
    ,"gwt-lib"
    ,"jar"
    ,"kjar"
    ,"maven-archetype"
    ,"maven-module"
    ,"maven-plugin"
    ,"pom"
    ,"takari-maven-plugin"
    ,"tar.gz"
    ,"test-jar"
    ,"war"
    ,"xml"
    ,"zip"
    ]

knownScopes :: [Text]
knownScopes =
    ["compile"
    ,"provided"
    ,"runtime"
    ,"system"
    ,"test"
    ]


toTree :: TGF -> Tree NodeId
toTree tgf =
  -- Assuming root of the tree is the first node declared
  let rootId = fst . head $ nodeDeclarations tgf
  in buildTree rootId $ edgeDeclarations tgf


buildTree :: NodeId -> [EdgeData] -> Tree NodeId
buildTree rootId edges =
  let childrenOfRoot = mapMaybe (\(fromNodeId, toNodeId, _edgeText) -> if rootId == fromNodeId then Just toNodeId else Nothing) edges
  in Node rootId . fmap (`buildTree` edges) $ childrenOfRoot


{-| Extract Maven Coordinate of a maven module from the dependency tree root of it's associated dependency tree TGF file -}
extractRootCoordinate :: FilePath -> Text -> Either Text Coordinate
extractRootCoordinate pathOfTgf contentsOfTgf = case Txt.lines contentsOfTgf of
    (firstLine:_) -> case Txt.words firstLine of
        (_:gav:_) -> case Txt.splitOn ":" gav of
            [groupId, artifactId, packaging, version]
                -> Right $ mkCoord groupId artifactId packaging version
            _   -> Left $ "ERROR: I was expecting the first line of " <> filepathToText pathOfTgf <> " to contain 'groupId:artifactId:packaging:version' but it was '" <> gav <> "'"
        _ -> Left $ "ERROR: I was expecting the first line of " <> filepathToText pathOfTgf <> " to have two space-separated Strings"
    _ -> Left $ "ERROR: File " <> filepathToText pathOfTgf <> " was empty"
