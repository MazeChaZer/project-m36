module ProjectM36.Notifications where
import ProjectM36.Base
import ProjectM36.RelationalExpression
import ProjectM36.RelationalExpressionState
import Control.Monad.State
import qualified Data.Map as M
import Data.Either (isRight)

-- | Returns the notifications which should be triggered based on the transition from the first 'DatabaseContext' to the second 'DatabaseContext'.
notificationChanges :: Notifications -> DatabaseContext -> DatabaseContext -> Notifications
notificationChanges nots context1 context2 = M.filter notificationFilter nots
  where
    notificationFilter (Notification chExpr _) = let oldChangeEval = evalChangeExpr chExpr (RelationalExprStateElems context1)
                                                     newChangeEval = evalChangeExpr chExpr (RelationalExprStateElems context2) in
                                                 oldChangeEval /= newChangeEval && isRight oldChangeEval
    evalChangeExpr chExpr = evalState (evalRelationalExpr chExpr)

    
