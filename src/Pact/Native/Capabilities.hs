{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      :  Pact.Native.Capabilities
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Builtins for working with capabilities.
--

module Pact.Native.Capabilities
  ( capDefs
  , evalCap
  ) where


import Control.Lens
import Control.Monad
import Data.Default
import Data.Maybe (isJust)
import qualified Data.Set as S

import Pact.Eval
import Pact.Native.Internal
import Pact.Runtime.Capabilities
import Pact.Types.Capability
import Pact.Types.PactValue
import Pact.Types.Pretty
import Pact.Types.Runtime

capDefs :: NativeModule
capDefs =
  ("Capabilities",
   [ withCapability
   , installCapability
   , enforceGuardDef "enforce-guard"
   , requireCapability
   , composeCapability
   , emitEventDef
   ])

tvA :: Type n
tvA = mkTyVar "a" []

withCapability :: NativeDef
withCapability =
  defNative (specialForm WithCapability) withCapability'
  (funType tvA [("capability",TyFun $ funType' tTyBool []),("body",TyList TyAny)])
  [LitExample "(with-capability (UPDATE-USERS id) (update users id { salary: new-salary }))"]
  "Specifies and requests grant of _acquired_ CAPABILITY which is an application of a 'defcap' \
  \production. Given the unique token specified by this application, ensure \
  \that the token is granted in the environment during execution of BODY. \
  \'with-capability' can only be called in the same module that declares the \
  \corresponding 'defcap', otherwise module-admin rights are required. \
  \If token is not present, the CAPABILITY is evaluated, with successful completion \
  \resulting in the installation/granting of the token, which will then be revoked \
  \upon completion of BODY. Nested 'with-capability' calls for the same token \
  \will detect the presence of the token, and will not re-apply CAPABILITY, \
  \but simply execute BODY. 'with-capability' cannot be called from within \
  \an evaluating defcap. Acquire of a managed capability results in emission \
  \of the equivalent event."
  where
    withCapability' i [c@TApp{},body@TList{}] = gasUnreduced i [] $ do

      enforceNotWithinDefcap i "with-capability"

      -- evaluate in-module cap
      acquireResult <- evalCap i CapCallStack True (_tApp c)

      -- execute scoped code
      r <- reduceBody body

      -- pop if newly acquired
      when (acquireResult == NewlyAcquired) $ popCapStack (const (return ()))

      return r

    withCapability' i as = argsError' i as

installCapability :: NativeDef
installCapability =
  defNative "install-capability" installCapability'
  (funType tTyString
    [("capability",TyFun $ funType' tTyBool [])
    ])
  [LitExample "(install-capability (PAY \"alice\" \"bob\" 10.0))"]
  "Specifies, and provisions install of, a _managed_ CAPABILITY, defined in a 'defcap' \
  \in which a '@managed' tag designates a single parameter to be managed by a specified function. \
  \After install, CAPABILITY must still be brought into scope using 'with-capability', at which time \
  \the 'manager function' is invoked to validate the request. \
  \The manager function is of type \
  \'managed:<p> requested:<p> -> <p>', \
  \where '<p>' indicates the type of the managed parameter, such that for \
  \'(defcap FOO (bar:string baz:integer) @managed baz FOO-mgr ...)', \
  \the manager function would be '(defun FOO-mgr:integer (managed:integer requested:integer) ...)'. \
  \Any capability matching the 'static' (non-managed) parameters will cause this function to \
  \be invoked with the current managed value and that of the requested capability. \
  \The function should perform whatever logic, presumably linear, to validate the request, \
  \and return the new managed value representing the 'balance' of the request. \
  \NOTE that signatures scoped to a managed capability cause the capability to be automatically \
  \provisioned for install similarly to one installed with this function."

  where
    installCapability' i as = case as of
      [TApp cap _] -> gasUnreduced i [] $ do

        enforceNotWithinDefcap i "install-capability"

        (ucap,_,_) <- appToCap cap
        -- note that this doesn't actually "install" but instead
        -- collects as "autonomous", as opposed to sig-provisioned caps.
        evalCapabilities . capAutonomous %= S.insert ucap
        return $ tStr $ "Installed capability"

      _ -> argsError' i as


-- | Given cap app, enforce in-module call, eval args to form capability,
-- and attempt to acquire. Return capability if newly-granted. When
-- 'inModule' is 'True', natives can only be invoked within module code.
evalCap :: HasInfo i => i -> CapScope -> Bool -> App (Term Ref) -> Eval e CapEvalResult
evalCap i scope inModule a@App{..} = do
      (cap,d,prep) <- appToCap a
      when inModule $ guardForModuleCall _appInfo (_dModule d) $ return ()
      evalUserCapability i capFuns scope cap d $ do
        computeUserAppGas d _appInfo
        void $ evalUserAppBody d prep _appInfo reduceBody


-- | Continuation to tie the knot with Pact.Eval (ie, 'apply') and also because the capDef is
-- more accessible here.
applyMgrFun
  :: Def Ref
  -- ^ manager def
  -> PactValue
  -- ^ MANAGED argument
  -> PactValue
  -- ^ REQUESTED argument
  -> Eval e PactValue
applyMgrFun mgrFunDef mgArg capArg = doApply (map fromPactValue [mgArg,capArg])
  where

    doApply as = do
      r <- apply (App appVar [] (getInfo mgrFunDef)) as
      case toPactValue r of
        Left e -> evalError' mgrFunDef $ "Invalid return value from mgr function: " <> pretty e
        Right v -> return v

    appVar = TVar (Ref (TDef mgrFunDef (getInfo mgrFunDef))) def

capFuns :: (ApplyMgrFun e,InstallMgd e)
capFuns = (applyMgrFun,installSigCap)

installSigCap :: InstallMgd e
installSigCap SigCapability{..} cdef = do
  r <- evalCap cdef CapManaged True $ mkApp cdef (map fromPactValue _scArgs)
  case r of
    NewlyInstalled mc -> return mc
    _ -> evalError' cdef "Unexpected result from managed sig cap install"
  where
    mkApp d@Def{} as =
      App (TVar (Ref (TDef d (getInfo d))) (getInfo d))
          (map liftTerm as) (getInfo d)


enforceNotWithinDefcap :: HasInfo i => i -> Doc -> Eval e ()
enforceNotWithinDefcap i msg = defcapInStack Nothing >>= \p -> when p $
  evalError' i $ msg <> " not allowed within defcap execution"

requireCapability :: NativeDef
requireCapability =
  defNative "require-capability" requireCapability'
  (funType tTyBool [("capability",TyFun $ funType' tTyBool [])])
  [LitExample "(require-capability (TRANSFER src dest))"]
  "Specifies and tests for existing grant of CAPABILITY, failing if not found in environment."
  where
    requireCapability' :: NativeFun e
    requireCapability' i [TApp a@App{} _] = gasUnreduced i [] $ do
      (cap,_,_) <- appToCap a
      granted <- capabilityAcquired cap
      unless granted $ ifExecutionFlagSet FlagDisablePact44
        (evalError' i ("require-capability: not granted: " <> pretty cap))
        (failTx (_faInfo i) ("require-capability: not granted: " <> pretty cap))
      return $ toTerm True
    requireCapability' i as = argsError' i as

composeCapability :: NativeDef
composeCapability =
  defNative "compose-capability" composeCapability'
  (funType tTyBool [("capability",TyFun $ funType' tTyBool [])])
  [LitExample "(compose-capability (TRANSFER src dest))"]
  "Specifies and requests grant of CAPABILITY which is an application of a 'defcap' \
  \production, only valid within a (distinct) 'defcap' body, as a way to compose \
  \CAPABILITY with the outer capability such that the scope of the containing \
  \'with-capability' call will \"import\" this capability. Thus, a call to \
  \'(with-capability (OUTER-CAP) OUTER-BODY)', where the OUTER-CAP defcap calls \
  \'(compose-capability (INNER-CAP))', will result in INNER-CAP being granted \
  \in the scope of OUTER-BODY."
  where
    composeCapability' :: NativeFun e
    composeCapability' i [TApp app _] = gasUnreduced i [] $ do
      -- enforce in defcap
      defcapInStack (Just 1) >>= \p -> unless p $ evalError' i "compose-capability valid only within defcap body"
      -- evalCap as composed, which will install onto head of pending cap
      void $ evalCap i CapComposed True app
      return $ toTerm True
    composeCapability' i as = argsError' i as

-- | Traverse up the call stack returning 'True' if a containing
-- defcap application is found.
defcapInStack :: Maybe Int -> Eval e Bool
defcapInStack limit = use evalCallStack >>= return . go limit
  where
    go :: Maybe Int -> [StackFrame] -> Bool
    go Nothing s = isJust . preview (funapps . faDefType . _Defcap) $ s
    go (Just limit') s = case take limit'
      (toListOf (traverse . sfApp . _Just . _1 . to defcapIfUserApp . traverse) s) of
      [] -> False
      dts -> Defcap `elem` dts

    defcapIfUserApp FunApp{..} = _faDefType <$ _faModule

    funapps :: Traversal' [StackFrame] FunApp
    funapps = traverse . sfApp . _Just . _1



emitEventDef :: NativeDef
emitEventDef =
  defNative "emit-event" emitEvent'
  (funType tTyBool [("capability",TyFun $ funType' tTyBool [])])
  [LitExample "(emit-event (TRANSFER \"Bob\" \"Alice\" 12.0))"]
  "Emit CAPABILITY as event without evaluating body of capability. \
  \Fails if CAPABILITY is not @managed or @event."
  where
    emitEvent' :: NativeFun e
    emitEvent' i [TApp a _] = gasUnreduced i [] $ do
      (cap,d,_prep) <- appToCap a
      enforceMeta i d
      guardForModuleCall (getInfo i) (_dModule d) $ return ()
      emitCapability i cap
      return $ toTerm True
    emitEvent' i as = argsError' i as

    enforceMeta i Def{..} = case _dDefMeta of
      (Just (DMDefcap dmeta)) -> case dmeta of
        -- being total here in case we have another value later
        DefcapManaged {} -> return ()
        DefcapEvent -> return ()
      _ -> evalError' i $ "emit-event: must be managed or event defcap"
