import "./lib/polyfills"; // first: mera needs crypto.getRandomValues at import time
import { registerRootComponent } from "expo";
import App from "./App";

registerRootComponent(App);
