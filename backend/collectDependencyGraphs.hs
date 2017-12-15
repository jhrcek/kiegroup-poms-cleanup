#!/usr/bin/env stack
-- stack runghc
  --package turtle
  --package system-filepath
  --package text

{-
This script will copy all of those deps.tgf files generated by mvn dependency:tree command below
to "dependency-trees" directory and will rename it to the form "<groupId>:<artifactId>:<packaging>:<version>.tgf"

PREREQUISITE: this script is placed in a folder into which all kiegroup projects have been cloned

USAGE
$ ./droolsjbpm-build-bootstrap/script/mvn-all.sh dependency:tree -DoutputType=tgf -DoutputFile=deps.tgf
$ ./collectDependencyGraphs.hs
-}

{-# LANGUAGE OverloadedStrings #-}
import qualified Control.Foldl as Foldl
import Data.List
import Data.Text (Text)
import qualified Data.Text as Txt
import qualified Data.Text.IO as Txt
import Data.Tree
import qualified Filesystem.Path.CurrentOS as OSPath
import Prelude hiding (FilePath)
import qualified TGF
import Turtle
import qualified Turtle.Pattern as Pattern


main :: IO ()
main = do
    prepareOutputFolder
    putStrLn "Analyzing module structure of repos"
    moduleCoordinatesTree <- analyzeModuleStructure
    putStrLn . drawTree $ fmap show moduleCoordinatesTree
    -- TODO save module structure in appropriate format

    putStr "Copying dependency reports to 'dependency-trees' directory "
    sh $ findDependencyReports >>= copyToTarget
    copiedFilesCount <- fold (Turtle.find (suffix  ".tgf") "dependency-trees") Foldl.length
    putStrLn $ show copiedFilesCount <> " files copied"


prepareOutputFolder :: IO ()
prepareOutputFolder = do
    alreadyExists <- testdir depTreesDir
    when alreadyExists $ rmtree depTreesDir
    mkdir depTreesDir


depTreesDir :: FilePath
depTreesDir = "dependency-trees"


findDependencyReports :: Shell FilePath
findDependencyReports = Turtle.find (Pattern.suffix "/deps.tgf") "."


analyzeModuleStructure :: IO (Tree TGF.Coordinate)
analyzeModuleStructure = do
    tgfFiles <- fold findDependencyReports Foldl.list
    -- put directory structure into tree
    let splitFiles = splitDirectories <$> sort tgfFiles
        dirsTree = buildModuleDirsTree splitFiles --forest of simple dir names, at each node there should be deps.tgf file

    -- There should be deps.tgf at each node, so read project coordinates from them
    buildModuleCoordinatesTree dirsTree


buildModuleDirsTree :: [[FilePath]] -> Tree FilePath
buildModuleDirsTree ps = Node
    (head $ head ps)
    (map buildModuleDirsTree . groupBy (\a b -> head a == head b) . sort $ filter ((>1).length {-ignore deps.tgf-}) $ map tail ps)


buildModuleCoordinatesTree :: Tree FilePath -> IO (Tree TGF.Coordinate)
buildModuleCoordinatesTree (Node curDir subdirs) = do
  let tgfFile = curDir </> OSPath.fromText "deps.tgf"
  tgfFileExists <- testfile tgfFile
  coordHere <- if tgfFileExists
         then do
            contents <- Txt.readFile . Txt.unpack $ filepathToText tgfFile
            let eitherCoord = extractCoordinate tgfFile contents
            return $ either (const $ TGF.mkCoord "" "" "" "") id eitherCoord
         else do
           Txt.putStrLn $ "WARNING: file " <> filepathToText tgfFile <> " doesn't exist!"
           return $ TGF.mkCoord "" "" "" ""
  subdirCoords <- mapM (\(Node rt children) -> buildModuleCoordinatesTree $  Node (curDir </> rt) children) subdirs
  return $ Node coordHere subdirCoords


{- We want to move the output file of dependency:analyze, like "drools-wb/drools-wb-webapp/deps.tgf"
   to a single folder where each file will have the name of the form "<groupId>:<artifactId>:<packaging>:<version>.tgf"
-}
toTargetFileName :: FilePath -> IO FilePath
toTargetFileName sourceReport = do
    reportContents <- Txt.readFile . Txt.unpack $ filepathToText sourceReport
    case extractCoordinate sourceReport reportContents of
      Right coord -> return $ depTreesDir </> OSPath.fromText (Txt.pack (show coord)) <.> "tgf"
      Left er     -> die er


{-| Extract Maven Coordinate of a module from it's associated TGF file -}
extractCoordinate :: FilePath -> Text -> Either Text TGF.Coordinate
extractCoordinate pathOfTgf contentsOfTgf = case Txt.lines contentsOfTgf of
    (firstLine:_) -> case Txt.words firstLine of
        (_:gav:_) -> case Txt.splitOn ":" gav of
            [groupId, artifactId, packaging, version] -> Right $ TGF.mkCoord groupId artifactId packaging version
            _                                         -> Left $ "ERROR: I was expecting the first line of " <> filepathToText pathOfTgf <> " to contain 'groupId:artifactId:packaging:version' but it was '" <> gav <> "'"
        _ -> Left $ "ERROR: I was expecting the first line of " <> filepathToText pathOfTgf <> " to have two space-separated Strings"
    _ -> Left $ "ERROR: File " <> filepathToText pathOfTgf <> " was empty"


copyToTarget :: FilePath -> Shell ()
copyToTarget sourceReport = liftIO $ do
    targetReport <- liftIO $ toTargetFileName sourceReport
    targetAlreadyExists <- testfile targetReport
    if targetAlreadyExists
        then putStrLn $ "WARNING: " <> show targetReport <> " already exists - NOT overwriting!"
        else putStr "." {-progress indicator -} >> cp sourceReport targetReport


filepathToText :: FilePath -> Text
filepathToText = either (error . show) id . OSPath.toText
