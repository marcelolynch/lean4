-- This module imports SlowChain.A.
-- After cancellation (triggered by Fail1/Fail2), SlowChain.A still compiles
-- successfully (it's already in-flight). The bug is that once A finishes,
-- the mapM task chain in recBuildLean fires and compiles B anyway, because
-- the task callback never checks the cancellation token.
import SlowChain.A
