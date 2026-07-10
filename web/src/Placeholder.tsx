import { ReactNode } from "react";

interface PlaceholderProps {
  title: string;
  children?: ReactNode;
}

// simple stand-in used by the views that don't have real content yet
function Placeholder({ title, children }: PlaceholderProps) {
  return (
    <div className="p-4">
      <h4 className="mb-1">{title}</h4>
      <div className="text-secondary">{children ?? "coming soon"}</div>
    </div>
  );
}

export default Placeholder;
