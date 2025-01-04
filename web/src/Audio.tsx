import { useEffect, useRef } from "react";
import { player } from "./Player";

function Audio() {
  const audioRef = useRef<HTMLAudioElement>(null);

  useEffect(() => {
    player().setAudioRef(audioRef.current!);
  }, [audioRef]);
  return <audio ref={audioRef} />;
}

export default Audio;
