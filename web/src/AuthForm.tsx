import { useState } from "react";
import { Alert, Button, Container, Form, Spinner } from "react-bootstrap";
import axios from "axios";
import DelayedElement from "./DelayedElement";
import { AuthResponse } from "./generated/messages";

interface AuthFormProps {
  setAuthToken: (authToken: string) => void;
}

function AuthForm({ setAuthToken }: AuthFormProps) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [inflight, setInflight] = useState(false);
  const [error, setError] = useState("");

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setInflight(true);
    setError("");

    const formData = new FormData(event.currentTarget);

    try {
      const { data } = await axios.postForm("/api/auth", formData, {
        responseType: "arraybuffer",
      });

      const msg = AuthResponse.deserialize(data);
      if (msg.response === "token") {
        setAuthToken(msg.token);
      } else {
        setError(msg.error);
      }
    } catch (error) {
      setError(
        "An error occurred while trying to authenticate. Please try again."
      );
      console.error(error);
    }
    setInflight(false);
  };

  return (
    <Container style={{ maxWidth: "444px" }}>
      <div
        style={{
          paddingTop: "40px",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
        }}
      >
        <h5>Warehouse</h5>
        <Form
          onSubmit={handleSubmit}
          noValidate
          style={{ marginTop: "8px", width: "100%" }}
        >
          {error && <Alert variant="danger">{error}</Alert>}
          <Form.Group className="mb-3" controlId="username">
            <Form.Label>Username</Form.Label>
            <Form.Control
              required
              name="username"
              value={username}
              onChange={(event) => setUsername(event.target.value)}
            />
          </Form.Group>
          <Form.Group className="mb-3" controlId="password">
            <Form.Label>Password</Form.Label>
            <Form.Control
              required
              name="password"
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
            />
          </Form.Group>
          <Button
            type="submit"
            className="w-100 position-relative"
            style={{ marginTop: "24px", marginBottom: "16px" }}
            disabled={inflight}
          >
            Sign In
            {inflight && (
              <DelayedElement>
                <span
                  style={{
                    position: "absolute",
                    top: "50%",
                    left: "50%",
                    transform: "translate(-50%, -50%)",
                  }}
                >
                  <Spinner animation="border" size="sm" />
                </span>
              </DelayedElement>
            )}
          </Button>
        </Form>
      </div>
    </Container>
  );
}

export default AuthForm;
