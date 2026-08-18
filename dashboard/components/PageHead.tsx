export default function PageHead({
  title,
  subtitle,
  right,
}: {
  title: string;
  subtitle?: string;
  right?: React.ReactNode;
}) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-x-4 gap-y-3 mb-6">
      <div className="min-w-0">
        <h1 className="font-display text-h1 font-medium">{title}</h1>
        {subtitle && <p className="text-muted text-body mt-1">{subtitle}</p>}
      </div>
      {right}
    </div>
  );
}
