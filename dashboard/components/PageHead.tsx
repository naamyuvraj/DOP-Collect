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
    <div className="flex items-end justify-between gap-4 mb-6">
      <div className="min-w-0">
        <h1 className="text-h1 font-semibold">{title}</h1>
        {subtitle && <p className="text-muted text-body mt-1">{subtitle}</p>}
      </div>
      {right}
    </div>
  );
}
