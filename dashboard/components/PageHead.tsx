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
    <div className="flex items-end justify-between mb-5">
      <div>
        <h1 className="text-[22px] font-extrabold leading-none">{title}</h1>
        {subtitle && <p className="text-muted text-[13px] mt-1.5">{subtitle}</p>}
      </div>
      {right}
    </div>
  );
}
