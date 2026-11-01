// About: name, version, the placeholder-name note and the independence statement (rule 8).
import { useQuery } from "@tanstack/react-query";

import { ErrorAlert, LoadingSkeleton } from "@/components/common";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { useIpc } from "@/lib/ipc";
import { notAffiliatedStatement } from "@/strings/providers";

export default function AboutScreen() {
  const ipc = useIpc();
  const info = useQuery({ queryKey: ["app_info"], queryFn: () => ipc.get_app_info() });

  return (
    <div className="flex max-w-[65ch] flex-col gap-6">
      {info.isPending && <LoadingSkeleton rows={1} label="Loading app info" />}
      {info.isError && <ErrorAlert error={info.error} />}
      {info.isSuccess && (
        <Card>
          <CardHeader>
            <CardTitle>
              <h2 className="text-xl font-semibold">{info.data.name}</h2>
            </CardTitle>
            <CardDescription>
              Version <span className="font-mono text-[13px]">{info.data.version}</span>
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-col gap-3 text-sm">
            <p className="text-muted-foreground">
              &quot;{info.data.name}&quot; and{" "}
              <span className="font-mono text-[13px]">{info.data.identifier}</span> are placeholder
              names and will change before release.
            </p>
          </CardContent>
        </Card>
      )}
      <section aria-labelledby="about-independence" className="flex flex-col gap-2">
        <h2 id="about-independence" className="text-base font-semibold">
          Independence
        </h2>
        <p data-testid="not-affiliated">{notAffiliatedStatement()}</p>
        <p className="text-sm text-muted-foreground">
          Harness checks the command-line tools installed on this computer. Each tool handles its
          own sign-in. This build cannot run AI tasks or workers.
        </p>
      </section>
    </div>
  );
}
