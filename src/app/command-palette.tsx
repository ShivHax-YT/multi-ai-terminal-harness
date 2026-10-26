// ⌘K palette: navigation and theme only. It never approves, kills, takes over or does anything else that acts on a
// session, plan or provider (rule 9; src/app/shell.test.tsx checks every item).
import { Monitor, Moon, Sun } from "lucide-react";
import { useNavigate } from "react-router";

import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandShortcut,
} from "@/components/ui/command";

import { ABOUT_ITEM, NAV_ITEMS, modKeyLabel } from "./nav";
import { THEME_LABELS, THEMES, useTheme, type ThemePreference } from "./theme";

const THEME_ICONS: Record<ThemePreference, typeof Sun> = {
  light: Sun,
  dark: Moon,
  system: Monitor,
};

export function CommandPalette({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const navigate = useNavigate();
  const { setTheme } = useTheme();
  const mod = modKeyLabel();

  const go = (path: string) => {
    onOpenChange(false);
    void navigate(path);
  };

  return (
    <CommandDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Command palette"
      description="Go to a screen or change the theme."
    >
      <CommandInput placeholder="Go to a screen or change the theme" />
      <CommandList>
        <CommandEmpty>No matching screen or theme.</CommandEmpty>
        <CommandGroup heading="Go to">
          {[...NAV_ITEMS, ABOUT_ITEM].map((item) => (
            <CommandItem
              key={item.id}
              value={`Go to ${item.label}`}
              onSelect={() => {
                go(item.path);
              }}
            >
              <item.icon aria-hidden="true" />
              {item.label}
              {item.digit !== undefined && (
                <CommandShortcut>{`${mod}${String(item.digit)}`}</CommandShortcut>
              )}
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandGroup heading="Theme">
          {THEMES.map((theme) => {
            const Icon = THEME_ICONS[theme];
            return (
              <CommandItem
                key={theme}
                value={`Theme ${THEME_LABELS[theme]}`}
                onSelect={() => {
                  setTheme(theme);
                  onOpenChange(false);
                }}
              >
                <Icon aria-hidden="true" />
                {`Theme: ${THEME_LABELS[theme]}`}
              </CommandItem>
            );
          })}
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
