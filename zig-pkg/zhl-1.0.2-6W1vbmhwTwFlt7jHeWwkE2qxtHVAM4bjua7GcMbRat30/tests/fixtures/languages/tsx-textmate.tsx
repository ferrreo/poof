type Props = { value: number };

export function View(props: Props) {
  return <section className="panel">{props.value}</section>;
}
