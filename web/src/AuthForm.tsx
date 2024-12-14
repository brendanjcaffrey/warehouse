import { useState, useEffect } from "react";
import {
  Alert,
  CircularProgress,
  Button,
  TextField,
  Box,
  Typography,
  Container,
} from "@mui/material";
import axios from "axios";
import library from "./Library";
import DelayedElement from "./DelayedElement";
import { AuthAttemptResponse } from "./generated/messages";

interface AuthFormProps {
  setAuthToken: (authToken: string) => void;
}

function AuthForm({ setAuthToken }: AuthFormProps) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [inflight, setInflight] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    // if we're ever showing the login form, clear the library
    library().clear();
  });

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setInflight(true);
    setError("");

    const formData = new FormData(event.currentTarget);

    try {
      const { data } = await axios.postForm("/api/auth", formData, {
        responseType: "arraybuffer",
      });

      const msg = AuthAttemptResponse.deserialize(data);
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
    <Container component="main" maxWidth="xs">
      <Box
        sx={{
          marginTop: 8,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
        }}
      >
        <Typography component="h1" variant="h5">
          Music Streamer
        </Typography>
        <Box component="form" onSubmit={handleSubmit} noValidate sx={{ mt: 1 }}>
          {error && <Alert severity="error">{error}</Alert>}
          <TextField
            margin="normal"
            required
            fullWidth
            label="Username"
            name="username"
            value={username}
            onChange={(event) => setUsername(event.target.value)}
          />
          <TextField
            margin="normal"
            required
            fullWidth
            label="Password"
            name="password"
            type="password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
          />
          <Button
            type="submit"
            fullWidth
            variant="contained"
            sx={{ mt: 3, mb: 2 }}
            disabled={inflight}
          >
            Sign In
            {inflight && (
              <DelayedElement>
                <Box
                  sx={{
                    position: "absolute",
                    top: "50%",
                    left: "50%",
                    transform: "translate(-50%, -50%)",
                  }}
                >
                  <CircularProgress size={37} />
                </Box>
              </DelayedElement>
            )}
          </Button>
        </Box>
      </Box>
    </Container>
  );
}

export default AuthForm;
