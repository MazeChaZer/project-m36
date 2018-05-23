--parse type and data constructors
module TutorialD.Interpreter.Types where
import ProjectM36.Base
import Text.Megaparsec.Text
import Text.Megaparsec
import TutorialD.Interpreter.Base
import ProjectM36.DataTypes.Primitive
import qualified Data.Text as T

-- | Upper case names are type names while lower case names are polymorphic typeconstructor arguments.
-- data *Either a b* = Left a | Right b
typeConstructorDefP :: Parser TypeConstructorDef
typeConstructorDefP = ADTypeConstructorDef <$> capitalizedIdentifier <*> typeVarNamesP

typeVarNamesP :: Parser [TypeVarName]
typeVarNamesP = many uncapitalizedIdentifier 
  
-- data Either a b = *Left a* | *Right b*
dataConstructorDefP :: Parser DataConstructorDef
dataConstructorDefP = DataConstructorDef <$> capitalizedIdentifier <*> many dataConstructorDefArgP

-- data *Either a b* = Left *a* | Right *b*
dataConstructorDefArgP :: Parser DataConstructorDefArg
dataConstructorDefArgP = parens (DataConstructorDefTypeConstructorArg <$> typeConstructorP) <|>
                         DataConstructorDefTypeConstructorArg <$> typeConstructorP <|>
                         DataConstructorDefTypeVarNameArg <$> uncapitalizedIdentifier
  
--built-in, nullary type constructors
-- Int, Text, etc.
primitiveTypeConstructorP :: Parser TypeConstructor
primitiveTypeConstructorP = choice (relationTypeP ++ map (\(PrimitiveTypeConstructorDef name typ, _) -> do
                                               tName <- try $ symbol (T.unpack name)
                                               pure $ PrimitiveTypeConstructor tName typ)
                                       primitiveTypeConstructorMapping)
                            
-- relation{a Int} in type construction (no tuples parsed)
relationTypeP :: Parser TypeConstructor
relationTypeP = do
  reserved "relation"
  RelationAtomTypeConstructor <$> braces makeAttributeExprsP
  
--used in relation creation
makeAttributeExprsP :: RelationalMarkerExpr a => Parser [AttributeExprBase a]
makeAttributeExprsP = braces (sepBy attributeAndTypeNameP comma)

attributeAndTypeNameP :: RelationalMarkerExpr a => Parser (AttributeExprBase a)
attributeAndTypeNameP = AttributeAndTypeNameExpr <$> identifier <*> typeConstructorP <*> parseMarkerP
  
                            
-- *Either Int Text*, *Int*
typeConstructorP :: Parser TypeConstructor                  
typeConstructorP = primitiveTypeConstructorP <|>
                   TypeVariable <$> uncapitalizedIdentifier <|>
                   ADTypeConstructor <$> capitalizedIdentifier <*> many (parens typeConstructorP <|>
                                                                         monoTypeConstructorP)
                   
monoTypeConstructorP :: Parser TypeConstructor                   
monoTypeConstructorP = primitiveTypeConstructorP <|>
  ADTypeConstructor <$> capitalizedIdentifier <*> pure [] <|>
  TypeVariable <$> uncapitalizedIdentifier
                   



