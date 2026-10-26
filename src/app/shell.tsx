// App shell: sidebar (⌘1-⌘7 + About), header (page title, ⌘K button, theme menu), content (max 1200px).
// No route-transition animation.
import { Search } from "lucide-react";
import { Suspense, useEffect, useState } from "react";
import { NavLink, Outlet, useLocation, useNavigate } from "react-router";

import { LoadingSkeleton } from "@/components/common";
import { Button } from "@/components/ui/button";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar";

import { CommandPalette } from "./command-palette";
import { ABOUT_ITEM, NAV_ITEMS, modKeyLabel, navItemFor, type NavItem } from "./nav";
import { ThemeMenu } from "./theme-menu";

function NavEntry({ item, active, mod }: { item: NavItem; active: boolean; mod: string }) {
  return (
    <SidebarMenuItem>
      <SidebarMenuButton asChild isActive={active} tooltip={item.label}>
        <NavLink to={item.path} aria-current={active ? "page" : undefined}>
          <item.icon aria-hidden="true" />
          <span>{item.label}</span>
          {item.digit !== undefined && (
            <kbd className="ml-auto font-mono text-xs text-muted-foreground">
              {`${mod}${String(item.digit)}`}
            </kbd>
          )}
        </NavLink>
      </SidebarMenuButton>
    </SidebarMenuItem>
  );
}

export function Shell() {
  const location = useLocation();
  const navigate = useNavigate();
  const [paletteOpen, setPaletteOpen] = useState(false);
  const mod = modKeyLabel();
  const current = navItemFor(location.pathname);
  const title = current?.label ?? "Harness";

  useEffect(() => {
    document.title = `${title} - Harness`;
  }, [title]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey) return;
      if (e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((open) => !open);
        return;
      }
      const item = NAV_ITEMS.find((n) => n.digit !== undefined && String(n.digit) === e.key);
      if (item !== undefined) {
        e.preventDefault();
        setPaletteOpen(false);
        void navigate(item.path);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("keydown", onKey);
    };
  }, [navigate]);

  return (
    <SidebarProvider>
      <Sidebar collapsible="icon">
        <SidebarHeader>
          <div className="px-2 py-1.5 text-base font-semibold">Harness</div>
        </SidebarHeader>
        <nav aria-label="Main navigation" className="flex min-h-0 flex-1 flex-col">
          <SidebarContent>
            <SidebarGroup>
              <SidebarGroupContent>
                <SidebarMenu>
                  {NAV_ITEMS.map((item) => (
                    <NavEntry
                      key={item.id}
                      item={item}
                      active={current?.id === item.id}
                      mod={mod}
                    />
                  ))}
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          </SidebarContent>
          <SidebarFooter>
            <SidebarMenu>
              <NavEntry item={ABOUT_ITEM} active={current?.id === "about"} mod={mod} />
            </SidebarMenu>
          </SidebarFooter>
        </nav>
      </Sidebar>
      <SidebarInset>
        <header className="flex h-14 shrink-0 items-center gap-3 border-b bg-background px-4">
          <SidebarTrigger aria-label="Toggle sidebar" />
          <h1 className="text-2xl font-semibold">{title}</h1>
          <div className="ml-auto flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => {
                setPaletteOpen(true);
              }}
              aria-label="Open command palette"
            >
              <Search aria-hidden="true" />
              <span>Go to</span>
              <kbd className="font-mono text-xs text-muted-foreground">{`${mod}K`}</kbd>
            </Button>
            <ThemeMenu />
          </div>
        </header>
        <main className="mx-auto w-full max-w-[1200px] flex-1 p-6">
          <Suspense fallback={<LoadingSkeleton label="Loading screen" />}>
            <Outlet />
          </Suspense>
        </main>
      </SidebarInset>
      <CommandPalette open={paletteOpen} onOpenChange={setPaletteOpen} />
    </SidebarProvider>
  );
}
