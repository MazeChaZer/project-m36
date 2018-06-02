--compiling the script requires the IO monad because it must load modules from the filesystem, so we create the function and generate the requisite DatabaseExpr here.
module TutorialD.Interpreter.DatabaseContextIOOperator where
import ProjectM36.Base

import TutorialD.Interpreter.Base
import TutorialD.Interpreter.Types
import Text.Megaparsec
import Text.Megaparsec.Text
import Data.Text
import Debug.Trace

addAtomFunctionExprP :: Parser DatabaseContextIOExpr
addAtomFunctionExprP = dbioexprP "addatomfunction" AddAtomFunction
  
addDatabaseContextFunctionExprP :: Parser DatabaseContextIOExpr
addDatabaseContextFunctionExprP = dbioexprP "adddatabasecontextfunction" AddDatabaseContextFunction

createArbitraryRelationP :: Parser DatabaseContextIOExpr
createArbitraryRelationP = do
  reserved "createarbitraryrelation"
  relVarName <- identifier
  attrExprs <- makeAttributeExprsP :: Parser [AttributeExpr]
  min' <- fromInteger <$> integer
  _ <- symbol "-"
  max' <- fromInteger <$> integer
  pure $ CreateArbitraryRelation relVarName attrExprs (min',max')
  
dbioexprP :: String -> (Text -> [TypeConstructor] -> Text -> DatabaseContextIOExpr) -> Parser DatabaseContextIOExpr
dbioexprP res adt = do
  reserved res
  funcName <- quotedString
  funcType <- atomTypeSignatureP
  funcScript <- quotedString
  pure $ adt funcName funcType funcScript

atomTypeSignatureP :: Parser [TypeConstructor]
atomTypeSignatureP = sepBy typeConstructorP arrow

dbContextIOExprP :: Parser DatabaseContextIOExpr
dbContextIOExprP = addAtomFunctionExprP <|> 
                   addDatabaseContextFunctionExprP <|> 
                   loadAtomFunctionsP <|>
                   loadDatabaseContextFunctionsP <|>
                   createArbitraryRelationP

loadAtomFunctionsP :: Parser DatabaseContextIOExpr
loadAtomFunctionsP = do
  reserved "loadatomfunctions"
  LoadAtomFunctions <$> quotedString <*> quotedString <*> fmap unpack quotedString

loadDatabaseContextFunctionsP :: Parser DatabaseContextIOExpr  
loadDatabaseContextFunctionsP = do
  reserved "loaddatabasecontextfunctions"
  LoadDatabaseContextFunctions <$> quotedString <*> quotedString <*> fmap unpack quotedString
                                             
