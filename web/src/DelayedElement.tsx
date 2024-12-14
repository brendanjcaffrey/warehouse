import { ReactElement, useState, useEffect, useRef } from "react";

interface DelayedElementProps {
  children: ReactElement;
}

export default function DelayedElement({ children }: DelayedElementProps) {
  const [showing, setShowing] = useState<boolean>(false);
  const timerRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    timerRef.current = window.setTimeout(() => {
      setShowing(true);
    }, 1000);

    return () => {
      if (timerRef.current) {
        clearTimeout(timerRef.current);
        timerRef.current = undefined;
      }
    };
  }, []);

  if (showing) {
    return children;
  } else {
    return <></>;
  }
}
