module Parser(parseProgram,pRegexTill) where

import Control.Monad
import Data.Char
import Data.List
import Data.Maybe
import Text.Parsec
import qualified Data.Map.Strict as Map

import AST


type Parser = Parsec String ()

parseProgram :: String -> String -> Either ParseError Program
parseProgram fname source = parse pProgram fname source

pProgram :: Parser Program
pProgram = do
    cmds <- catMaybes <$> pCmd `sepBy` pWhiteSeparator
    pWhitespace
    eof
    return $ Program cmds

pCmd :: Parser (Maybe Cmd)
pCmd = do
    pWhitespace
    choice [ pEmptyCommand >> return Nothing
           , Just <$> pNormalCmd ]

pEmptyCommand :: Parser ()
pEmptyCommand = pComment <|> lookAhead (eof <|> pSeparator)

pNormalCmd :: Parser Cmd
pNormalCmd = do
    addr <- pAddr2
    c <- anyChar
    (arity, parser) <- case Map.lookup c commandMap of
        Just pair -> return pair
        Nothing -> unexpected $ "Unknown command '" ++ [c] ++ "'"

    fun <- case (addr, arity) of
        (_, 2) -> parser
        (Addr2 _ _ _, _) -> unexpected $ "Command '" ++ [c] ++ "' cannot take a 2-part address"
        (Addr1 _ _, 1) -> parser
        (Addr1 _ _, _) -> unexpected $ "Command '" ++ [c] ++ "' cannot take an address"
        (NoAddr, _) -> parser

    return $ Cmd addr fun

commandMap :: Map.Map Char (Int, Parser Fun)
commandMap = Map.fromList
    [ ('{', (2, pCBlock)),
      ('a', (1, Append <$> pText)),
      ('b', (2, Branch <$> optionMaybe (try pLabel))),
      ('c', (2, Change <$> pText)),
      ('d', (2, return Delete)),
      ('D', (2, return DeleteNL)),
      ('g', (2, return Get)),
      ('G', (2, return GetAppend)),
      ('h', (2, return Hold)),
      ('H', (2, return HoldAppend)),
      ('i', (1, Insert <$> pText)),
      ('n', (2, return Next)),
      ('N', (2, return NextAppend)),
      ('p', (2, return Print)),
      ('P', (2, return PrintNL)),
      ('q', (1, return Quit)),
      ('s', (2, pCSubst)),
      ('t', (2, To <$> optionMaybe (try pLabel))),
      ('x', (2, return Exchange)),
      ('y', (2, pCTrans)),
      (':', (0, Label <$> pLabel)),
      ('=', (1, return LineNum)) ]
  where
    pCBlock :: Parser Fun
    pCBlock = do
        cmds <- catMaybes <$> try pCmd `endBy` pWhiteSeparator
        pWhitespace
        void $ char '}'
        return $ Block cmds

    pCSubst :: Parser Fun
    pCSubst = do
        (regex, repl) <- pSArgs
        flags <- pSFlags
        return $ Subst regex repl flags

    pCTrans :: Parser Fun
    pCTrans = do
        (pat, repl) <- pYArgs
        return $ Trans pat repl

pComment :: Parser ()
pComment = void $ char '#' >> manyTill anyChar (eof <|> lookAhead (void newline))

pLabel :: Parser String
pLabel = pWhitespace >> many1 (satisfy (\c -> c /= ';' && not (isSpace c)))

pAddr2 :: Parser Addr
pAddr2 = choice
    [ do base <- pBaseAddr
         choice [ do void $ char ','
                     base2 <- pBaseAddr
                     b <- pAddressNot
                     return $ Addr2 b base base2
                , do b <- pAddressNot
                     return $ Addr1 b base ]
    , return NoAddr ]

pBaseAddr :: Parser BaseAddr
pBaseAddr = choice
    [ ALine . read <$> many1 (satisfy isDigit)
    , char '$' >> return AEnd
    , ARegex <$> try (pStrictDelimited pRegexTill) ]

pAddressNot :: Parser Bool
pAddressNot = do
    pWhitespace
    isNothing <$> optionMaybe (char '!' >> pWhitespace)

pText :: Parser String
pText = do
    pWhitespace
    let intermediateTerm = void newline <|> void (char '\\') <|> eof
        finalTerm = void newline <|> eof
    lns <- many $ string "\\\n" >> manyTill anyChar (lookAhead intermediateTerm)
    void $ lookAhead finalTerm
    return $ intercalate "\n" lns

pSArgs :: Parser (Regex, RegRepl)
pSArgs = pDelimitedPair pRegexTill pRegReplTill

pYArgs :: Parser (String, String)
pYArgs = pDelimitedPair pStringTill pStringTill

pDelimitedPair :: (Char -> Parser a) -> (Char -> Parser b) -> Parser (a, b)
pDelimitedPair p1 p2 = do
    delim <- satisfy (\c -> c /= '\\' && c /= '\n')
    a <- p1 delim
    void $ char delim
    b <- p2 delim
    void $ char delim
    return (a, b)

pStrictDelimited :: (Char -> Parser a) -> Parser a
pStrictDelimited p = do
    delim <- char '/' <|> try (char '\\' >> anyChar)
    a <- p delim
    void $ char delim
    return a

pRegexTill :: Char -> Parser Regex
pRegexTill delim = pRegConcat (lookAhead $ char delim)
  where
    pRegConcat :: Parsec String () a -> Parsec String () Regex
    pRegConcat delimp = RegConcat <$> manyTill pSimpleRE (try delimp)
    pSimpleRE = do
        base <- pRegAnchorLeft <|> pRegAnchorRight <|>
                pRegGroup <|> pRegBackref <|> pRegClass <|>
                pRegAny <|> pRegChar
        pRegStar base <|> pRegRep base <|> return base
    pRegAnchorLeft = char '^' >> return RegAnchorLeft
    pRegAnchorRight = char '$' >> return RegAnchorRight
    pRegGroup = try (string "\\(") >> pRegConcat (string "\\)") >>= \r -> return (RegGroup r 0)
    pRegBackref = try $ char '\\' >> (RegBackref . read . pure <$> digit)
    pRegAny = char '.' >> return RegAny
    pRegChar = RegChar <$>
        ((try (string "\\n") >> return '\n') <|>
         try (char '\\' >> (satisfy (not . isAlphaNum))) <|>
         satisfy (/= '\\'))
    pRegStar :: Regex -> Parsec String () Regex
    pRegStar r = char '*' >> return (RegStar r)
    pRegRep :: Regex -> Parsec String () Regex
    pRegRep r = do
        void $ try (string "\\{")
        n <- read <$> many1 digit
        choice [try (string "\\}") >> return (RegRep r n (Just n))
               ,char ',' >> choice [try (string "\\}") >> return (RegRep r n Nothing)
                                   ,do m <- read <$> many1 digit
                                       void $ string "\\}"
                                       return (RegRep r n (Just m))]]

    pRegClass = do
        void $ char '['
        pos <- isNothing <$> optionMaybe (char '^')
        s1 <- option [] (pure . RCChar <$> char ']')
        s2 <- manyTill pRegClassItem (lookAhead $ string "]" <|> try (string "-]"))
        s3 <- option [] (pure . RCChar <$> char '-')
        void $ char ']'
        return $ RegClass pos (s1 ++ s2 ++ s3)
    pRegClassItem = pRCRange <|> (RCChar <$> anyChar)
    pRCRange = try $ do
        a <- anyChar
        void $ char '-'
        b <- satisfy (/= ']')
        return $ RCRange a b

pRegReplTill :: Char -> Parser RegRepl
pRegReplTill delim = RegRepl <$> manyTill pItem (lookAhead $ char delim)
  where
    pItem = (try (string "\\n") >> return (RRChar '\n')) <|>
            (try $ char '\\' >> satisfy (not . isAlphaNum) >>= \c -> return (RRChar c)) <|>
            (char '\\' >> digit >>= \c -> return (RRBackref (read [c]))) <|>
            (char '&' >> return (RRBackref 0)) <|>
            (RRChar <$> anyChar)

pStringTill :: Char -> Parser String
pStringTill delim = do
    c <- lookAhead anyChar
    if c == delim then return ""
    else if c == '\\' then anyChar >: (anyChar >: pStringTill delim)
    else anyChar >: pStringTill delim
  where
    (>:) = liftM2 (:)

pSFlags :: Parser SFlags
pSFlags = choice
    [ char 'g' >> pSFlags >>= \f -> return $ f { sfGlob = True }
    , char 'p' >> pSFlags >>= \f -> return $ f { sfPrint = True }
    , many1 digit >>= \n -> pSFlags >>= \f -> return $ f { sfNth = Just (read n) }
    , return (SFlags Nothing False False) ]

pWhiteSeparator :: Parser ()
pWhiteSeparator = pWhitespace >> pSeparator

pSeparator :: Parser ()
pSeparator = void $ newline <|> char ';'

pWhitespace :: Parser ()
pWhitespace = void $ many $ satisfy (\c -> c == ' ' || c == '\t')
