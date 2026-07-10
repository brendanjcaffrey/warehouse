import { Button, ButtonProps } from "react-bootstrap";

const ICON_BUTTON_CLASS = "text-body p-1 lh-1 text-decoration-none";

const IconButton = ({ className, ...props }: ButtonProps) => (
  <Button
    variant="link"
    className={
      className ? `${ICON_BUTTON_CLASS} ${className}` : ICON_BUTTON_CLASS
    }
    {...props}
  />
);

export default IconButton;
