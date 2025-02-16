{-# LANGUAGE CPP             #-}
{-# LANGUAGE GADTs           #-}
{-# LANGUAGE RecordWildCards #-}

module Ide.Plugin.Class.ExactPrint where

import           Control.Monad.Trans.Maybe
import qualified Data.Text                               as T
import           Development.IDE.GHC.Compat
import           Ide.Plugin.Class.Types
import           Ide.Plugin.Class.Utils
import           Language.Haskell.GHC.ExactPrint
import           Language.Haskell.GHC.ExactPrint.Parsers

import           Data.Either.Extra                       (eitherToMaybe)
import           GHC.Parser.Annotation

makeEditText :: Monad m => ParsedModule -> DynFlags -> AddMinimalMethodsParams -> MaybeT m (T.Text, T.Text)
-- addMethodDecls :: ParsedSource -> [(LHsDecl GhcPs, LHsDecl GhcPs)] -> Range -> Bool -> TransformT Identity (Located HsModule)
makeEditText pm df AddMinimalMethodsParams{..} = do
    mDecls <- MaybeT . pure $ traverse (makeMethodDecl df) methodGroup
    let ps = makeDeltaAst $ pm_parsed_source pm
        old = T.pack $ exactPrint ps
        (ps', _, _) = runTransform (addMethodDecls ps mDecls range withSig)
        new = T.pack $ exactPrint ps'
    pure (old, new)

makeMethodDecl :: DynFlags -> (T.Text, T.Text) -> Maybe (LHsDecl GhcPs, LHsDecl GhcPs)
makeMethodDecl df (mName, sig) = do
    name <- eitherToMaybe $ parseDecl df (T.unpack mName) . T.unpack $ toMethodName mName <> " = _"
    sig' <- eitherToMaybe $ parseDecl df (T.unpack sig) $ T.unpack sig
    pure (name, sig')

addMethodDecls ps mDecls range withSig
    | withSig = go (concatMap (\(decl, sig) -> [sig, decl]) mDecls)
    | otherwise = go (map fst mDecls)
    where
    go inserting = do
        allDecls <- hsDecls ps
        let (before, ((L l inst): after)) = break (inRange range . getLoc) allDecls
        replaceDecls ps (before ++ (L l (addWhere inst)): (map newLine inserting ++ after))
    -- Add `where` keyword for `instance X where` if `where` is missing.
    --
    -- The `where` in ghc-9.2 is now stored in the instance declaration
    --   directly. More precisely, giving an `HsDecl GhcPs`, we have:
    --   InstD --> ClsInstD --> ClsInstDecl --> XCClsInstDecl --> (EpAnn [AddEpAnn], AnnSortKey),
    --   here `AnnEpAnn` keeps the track of Anns.
    --
    -- See the link for the original definition:
    --   https://hackage.haskell.org/package/ghc-9.2.1/docs/Language-Haskell-Syntax-Extension.html#t:XCClsInstDecl
    addWhere (InstD xInstD (ClsInstD ext decl@ClsInstDecl{..})) =
        let (EpAnn entry anns comments, key) = cid_ext
        in InstD xInstD (ClsInstD ext decl {
        cid_ext = (EpAnn
                    entry
                    (AddEpAnn AnnWhere (EpaDelta (SameLine 1) []) : anns)
                    comments
                    , key)
        })
    addWhere decl = decl

    newLine (L l e) =
        let dp = deltaPos 1 defaultIndent
        in L (noAnnSrcSpanDP (getLoc l) dp <> l) e

