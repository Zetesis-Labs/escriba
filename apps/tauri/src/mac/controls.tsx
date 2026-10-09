import { ChevronDown } from "lucide-react";
import type { ComponentType, ReactNode } from "react";
import { popupMenu, type MenuEntry } from "./native";
import "./controls.css";

type Icon = ComponentType<{ size?: number; strokeWidth?: number; className?: string }>;

export function Button({
  children,
  onClick,
  disabled,
  prominent,
  small,
  icon: IconView,
  title,
}: {
  children?: ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  prominent?: boolean;
  small?: boolean;
  icon?: Icon;
  title?: string;
}) {
  return (
    <button
      type="button"
      className={`mac-button ${prominent ? "prominent" : ""} ${small ? "small" : ""}`}
      onClick={onClick}
      disabled={disabled}
      title={title}
    >
      {IconView && <IconView size={small ? 12 : 14} strokeWidth={1.8} />}
      {children}
    </button>
  );
}

export function ToolbarButton({
  icon: IconView,
  label,
  onClick,
  disabled,
  help,
  showsTitle,
  tint,
}: {
  icon: Icon;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  help?: string;
  showsTitle?: boolean;
  tint?: string;
}) {
  return (
    <button
      type="button"
      className={`toolbar-item ${showsTitle ? "with-title" : ""}`}
      onClick={onClick}
      disabled={disabled}
      title={help ?? label}
      aria-label={label}
      style={tint ? { color: tint } : undefined}
    >
      <IconView size={16} strokeWidth={1.7} />
      {showsTitle && <span>{label}</span>}
    </button>
  );
}

export function ToolbarMenu({
  icon: IconView,
  label,
  menu,
  primary,
  disabled,
  help,
  showsTitle,
}: {
  icon: Icon;
  label: string;
  menu: () => MenuEntry[];
  primary?: () => void;
  disabled?: boolean;
  help?: string;
  showsTitle?: boolean;
}) {
  const open = (event: { currentTarget: Element }) => void popupMenu(menu(), event.currentTarget.closest(".toolbar-item") ?? undefined);
  if (primary)
    return (
      <span className={`toolbar-item split ${disabled ? "disabled" : ""}`} title={help ?? label}>
        <button type="button" className="split-main" onClick={primary} disabled={disabled} aria-label={label}>
          <IconView size={16} strokeWidth={1.7} />
          {showsTitle && <span>{label}</span>}
        </button>
        <button type="button" className="split-arrow" onClick={open} disabled={disabled} aria-label={`${label}: más opciones`}>
          <ChevronDown size={11} strokeWidth={2.2} />
        </button>
      </span>
    );
  return (
    <button
      type="button"
      className={`toolbar-item ${showsTitle ? "with-title" : ""}`}
      onClick={open}
      disabled={disabled}
      title={help ?? label}
      aria-label={label}
      aria-haspopup="menu"
    >
      <IconView size={16} strokeWidth={1.7} />
      {showsTitle && <span>{label}</span>}
      <ChevronDown size={11} strokeWidth={2.2} className="menu-indicator" />
    </button>
  );
}

export function ContentUnavailable({ title, icon: IconView, description }: { title: string; icon: Icon; description?: string }) {
  return (
    <div className="content-unavailable">
      <IconView size={40} strokeWidth={1.3} className="tertiary" />
      <div className="font-title3">{title}</div>
      {description && (
        <div className="secondary description">
          {description.split("\n").map((line) => (
            <p key={line}>{line}</p>
          ))}
        </div>
      )}
    </div>
  );
}

export function Spinner() {
  return <span className="spinner" role="progressbar" aria-label="En curso" />;
}

export function Sheet({ children, onCancel }: { children: ReactNode; onCancel: () => void }) {
  return (
    <div className="sheet-backdrop" onKeyDown={(event) => event.key === "Escape" && onCancel()}>
      <div className="sheet" role="dialog" aria-modal="true">
        {children}
      </div>
    </div>
  );
}

export function PopupButton<T extends string>({
  value,
  options,
  onChange,
  label,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange: (value: T) => void;
  label: string;
}) {
  const current = options.find((option) => option.value === value)?.label ?? "";
  return (
    <button
      type="button"
      className="popup-button"
      aria-label={label}
      onClick={(event) =>
        void popupMenu(
          options.map((option) => ({ kind: "item", text: option.label, checked: option.value === value, action: () => onChange(option.value) })),
          event.currentTarget,
        )
      }
    >
      <span>{current}</span>
      <ChevronDown size={11} strokeWidth={2.4} />
    </button>
  );
}

export function TextField({
  value,
  onChange,
  placeholder,
  autoFocus,
  onSubmit,
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  autoFocus?: boolean;
  onSubmit?: () => void;
}) {
  return (
    <input
      className="text-field selectable"
      value={value}
      placeholder={placeholder}
      autoFocus={autoFocus}
      onChange={(event) => onChange(event.target.value)}
      onKeyDown={(event) => event.key === "Enter" && onSubmit?.()}
      spellCheck={false}
    />
  );
}

export function FormSection({ header, footer, children }: { header?: string; footer?: ReactNode; children: ReactNode }) {
  return (
    <section className="form-section">
      {header && <div className="form-header font-headline">{header}</div>}
      <div className="form-group">{children}</div>
      {footer && <div className="form-footer font-caption secondary">{footer}</div>}
    </section>
  );
}

export function LabeledRow({ label, children }: { label: string; children?: ReactNode }) {
  return (
    <div className="form-row">
      <span className="form-label">{label}</span>
      <div className="form-value">{children}</div>
    </div>
  );
}

export function FormRow({ children }: { children: ReactNode }) {
  return <div className="form-row form-row-free">{children}</div>;
}

export function InlineField({
  value,
  onChange,
  placeholder,
  secure,
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  secure?: boolean;
}) {
  return (
    <input
      className="inline-field selectable"
      type={secure ? "password" : "text"}
      value={value}
      placeholder={placeholder}
      onChange={(event) => onChange(event.target.value)}
      spellCheck={false}
      autoCorrect="off"
      autoCapitalize="off"
    />
  );
}

export function ListBar({ children }: { children: ReactNode }) {
  return <div className="list-bar">{children}</div>;
}

export function ListBarButton({ icon: IconView, label, onClick, disabled }: { icon: Icon; label: string; onClick: (event: React.MouseEvent<HTMLButtonElement>) => void; disabled?: boolean }) {
  return (
    <button type="button" className="list-bar-button" onClick={onClick} disabled={disabled} title={label} aria-label={label}>
      <IconView size={14} strokeWidth={1.8} />
    </button>
  );
}
