// Plans route. The PlanView review screen (T-104) is the primary content. The T-133 sample workflow keeps its own
// component and is reached only through its "sim-N" plan ids, which the sample Lead form creates.
import { useParams } from "react-router";

import { isSamplePlanId } from "./plan-logic";
import { PlanScreen } from "./plan-screen";
import { SampleFlow } from "./sample-flow";

export default function PlansScreen() {
  const { planId } = useParams();
  if (isSamplePlanId(planId)) return <SampleFlow />;
  return <PlanScreen planId={planId} />;
}
