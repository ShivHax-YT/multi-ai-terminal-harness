import { screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { notAffiliatedStatement, PROVIDER_IDS, vendorName } from "@/strings/providers";
import { renderRoute } from "@/test/render";

describe("About (rule 8)", () => {
  it("shows the name, version, placeholder note and the independence statement", async () => {
    const { mock } = renderRoute("/about");
    expect(await screen.findByRole("heading", { level: 2, name: "Harness" })).toBeInTheDocument();
    expect(screen.getByText("0.1.0")).toBeInTheDocument();
    expect(screen.getByText(/placeholder\s+names/)).toBeInTheDocument();
    expect(screen.getByTestId("not-affiliated")).toHaveTextContent(notAffiliatedStatement());
    expect(mock.control.calls.map((c) => c.command)).toContain("get_app_info");
  });

  it("the statement names every vendor and says independent / not affiliated / not endorsed", () => {
    const text = notAffiliatedStatement();
    expect(text).toMatch(/independent/);
    expect(text).toMatch(/not affiliated with, endorsed by or sponsored by/);
    for (const id of PROVIDER_IDS) expect(text).toContain(vendorName(id));
    expect(text).not.toMatch(/official|powered by|partner/i);
  });

  it("shows an error when app info fails", async () => {
    renderRoute("/about", { mock: "errors" });
    expect(await screen.findByRole("alert")).toHaveTextContent("Something went wrong");
    expect(screen.getByTestId("not-affiliated")).toBeInTheDocument();
  });
});
