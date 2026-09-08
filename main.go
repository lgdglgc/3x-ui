// Package main is the entry point for the 3x-ui web panel application.
// It initializes the database, web server, and handles command-line operations for managing the panel.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	_ "unsafe"

	"github.com/mhsanaei/3x-ui/v3/config"
	"github.com/mhsanaei/3x-ui/v3/database"
	"github.com/mhsanaei/3x-ui/v3/logger"
	"github.com/mhsanaei/3x-ui/v3/sub"
	"github.com/mhsanaei/3x-ui/v3/util/crypto"
	"github.com/mhsanaei/3x-ui/v3/util/sys"
	"github.com/mhsanaei/3x-ui/v3/web"
	"github.com/mhsanaei/3x-ui/v3/web/global"
	"github.com/mhsanaei/3x-ui/v3/web/service"

	"github.com/joho/godotenv"
	"github.com/op/go-logging"
)

// runWebServer initializes and starts the web server for the 3x-ui panel.
func runWebServer() {
	log.Printf("Starting %v %v", config.GetName(), config.GetVersion())

	switch config.GetLogLevel() {
	case config.Debug:
		logger.InitLogger(logging.DEBUG)
	case config.Info:
		logger.InitLogger(logging.INFO)
	case config.Notice:
		logger.InitLogger(logging.NOTICE)
	case config.Warning:
		logger.InitLogger(logging.WARNING)
	case config.Error:
		logger.InitLogger(logging.ERROR)
	default:
		log.Fatalf("Unknown log level: %v", config.GetLogLevel())
	}

	godotenv.Load()

	err := database.InitDB(config.GetDBPath())
	if err != nil {
		log.Fatalf("Error initializing database: %v", err)
	}

	var server *web.Server
	server = web.NewServer()
	global.SetWebServer(server)
	err = server.Start()
	if err != nil {
		log.Fatalf("Error starting web server: %v", err)
		return
	}

	var subServer *sub.Server
	sub.SetDistFS(web.EmbeddedDist())
	service.RegisterSubLinkProvider(sub.NewLinkProvider())
	subServer = sub.NewServer()
	global.SetSubServer(subServer)
	err = subServer.Start()
	if err != nil {
		log.Fatalf("Error starting sub server: %v", err)
		return
	}

	sigCh := make(chan os.Signal, 1)
	// Trap shutdown signals
	signal.Notify(sigCh, syscall.SIGHUP, syscall.SIGTERM, sys.SIGUSR1, os.Interrupt)
	global.SetRestartHook(func() {
		select {
		case sigCh <- syscall.SIGHUP:
		default:
		}
	})
	for {
		sig := <-sigCh

		switch sig {
		case syscall.SIGHUP:
			logger.Info("Received SIGHUP signal. Restarting servers...")

			err := server.StopPanelOnly()
			if err != nil {
				logger.Debug("Error stopping web server:", err)
			}
			err = subServer.Stop()
			if err != nil {
				logger.Debug("Error stopping sub server:", err)
			}

			server = web.NewServer()
			global.SetWebServer(server)
			err = server.StartPanelOnly()
			if err != nil {
				log.Fatalf("Error restarting web server: %v", err)
				return
			}
			log.Println("Web 面板服务重启成功。")

			sub.SetDistFS(web.EmbeddedDist())
			subServer = sub.NewServer()
			global.SetSubServer(subServer)
			err = subServer.Start()
			if err != nil {
				log.Fatalf("Error restarting sub server: %v", err)
				return
			}
			log.Println("订阅服务重启成功。")
		case sys.SIGUSR1:
			logger.Info("Received USR1 signal, restarting xray-core...")
			err := server.RestartXray()
			if err != nil {
				logger.Error("Failed to restart xray-core:", err)
			}

		default:
			// --- FIX FOR TELEGRAM BOT CONFLICT (409) on full shutdown ---
			service.StopBot()
			// ------------------------------------------------------------

			server.Stop()
			subServer.Stop()
			log.Println("正在停止所有服务。")
			return
		}
	}
}

// resetSetting resets all panel settings to their default values.
func resetSetting() error {
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println("Failed to initialize database:", err)
		return err
	}

	settingService := service.SettingService{}
	err = settingService.ResetSettings()
	if err != nil {
		fmt.Println("Failed to reset settings:", err)
		return err
	} else {
		fmt.Println("Settings successfully reset.")
	}
	return nil
}

// showSetting displays the current panel settings if show is true.
func showSetting(show bool) {
	if show {
		settingService := service.SettingService{}
		port, err := settingService.GetPort()
		if err != nil {
			fmt.Println("get current port failed, error info:", err)
		}

		webBasePath, err := settingService.GetBasePath()
		if err != nil {
			fmt.Println("get webBasePath failed, error info:", err)
		}

		certFile, err := settingService.GetCertFile()
		if err != nil {
			fmt.Println("get cert file failed, error info:", err)
		}
		keyFile, err := settingService.GetKeyFile()
		if err != nil {
			fmt.Println("get key file failed, error info:", err)
		}

		userService := service.UserService{}
		userModel, err := userService.GetFirstUser()
		if err != nil {
			fmt.Println("get current user info failed, error info:", err)
		}

		if userModel.Username == "" || userModel.Password == "" {
			fmt.Println("当前用户名或密码为空")
		}

		fmt.Println("当前面板设置如下:")
		if certFile == "" || keyFile == "" {
			fmt.Println("警告: 面板未启用 SSL 安全证书")
		} else {
			fmt.Println("面板已启用 SSL 安全加密")
		}

		hasDefaultCredential := func() bool {
			return userModel.Username == "admin" && crypto.CheckPasswordHash(userModel.Password, "admin")
		}()

		fmt.Println("使用默认初始凭据:", hasDefaultCredential)
		fmt.Println("面板端口 (port):", port)
		fmt.Println("面板根路径 (webBasePath):", webBasePath)
	}
}

// updateTgbotEnableSts enables or disables the Telegram bot notifications based on the status parameter.
func updateTgbotEnableSts(status bool) {
	settingService := service.SettingService{}
	currentTgSts, err := settingService.GetTgbotEnabled()
	if err != nil {
		fmt.Println(err)
		return
	}
	logger.Infof("current enabletgbot status[%v],need update to status[%v]", currentTgSts, status)
	if currentTgSts != status {
		err := settingService.SetTgbotEnabled(status)
		if err != nil {
			fmt.Println(err)
			return
		} else {
			logger.Infof("SetTgbotEnabled[%v] success", status)
		}
	}
}

// updateTgbotSetting updates Telegram bot settings including token, chat ID, and runtime schedule.
func updateTgbotSetting(tgBotToken string, tgBotChatid string, tgBotRuntime string) {
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println("Error initializing database:", err)
		return
	}

	settingService := service.SettingService{}

	if tgBotToken != "" {
		err := settingService.SetTgBotToken(tgBotToken)
		if err != nil {
			fmt.Printf("Error setting Telegram bot token: %v\n", err)
			return
		}
		logger.Info("Successfully updated Telegram bot token.")
	}

	if tgBotRuntime != "" {
		err := settingService.SetTgbotRuntime(tgBotRuntime)
		if err != nil {
			fmt.Printf("Error setting Telegram bot runtime: %v\n", err)
			return
		}
		logger.Infof("Successfully updated Telegram bot runtime to [%s].", tgBotRuntime)
	}

	if tgBotChatid != "" {
		err := settingService.SetTgBotChatId(tgBotChatid)
		if err != nil {
			fmt.Printf("Error setting Telegram bot chat ID: %v\n", err)
			return
		}
		logger.Info("Successfully updated Telegram bot chat ID.")
	}
}

// updateSetting updates various panel settings including port, credentials, base path, listen IP, and two-factor authentication.
func updateSetting(port int, username string, password string, webBasePath string, listenIP string, resetTwoFactor bool) error {
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println("Database initialization failed:", err)
		return err
	}

	settingService := service.SettingService{}
	userService := service.UserService{}

	if port > 0 {
		err := settingService.SetPort(port)
		if err != nil {
			fmt.Println("设置端口失败:", err)
		} else {
			fmt.Printf("端口设置成功: %v\n", port)
		}
	}

	if username != "" || password != "" {
		err := userService.UpdateFirstUser(username, password)
		if err != nil {
			fmt.Println("更新用户名和密码失败:", err)
		} else {
			fmt.Println("用户名和密码更新成功")
		}
	}

	if webBasePath != "" {
		err := settingService.SetBasePath(webBasePath)
		if err != nil {
			fmt.Println("设置面板根路径失败:", err)
		} else {
			fmt.Println("面板根路径设置成功")
		}
	}

	if resetTwoFactor {
		err := settingService.SetTwoFactorEnable(false)

		if err != nil {
			fmt.Println("重置两步验证失败:", err)
		} else {
			settingService.SetTwoFactorToken("")
			fmt.Println("两步验证已成功重置")
		}
	}

	if listenIP != "" {
		err := settingService.SetListen(listenIP)
		if err != nil {
			fmt.Println("设置监听 IP 失败:", err)
		} else {
			fmt.Printf("监听 IP %v 设置成功\n", listenIP)
		}
	}

	return nil
}

// updateCert updates the SSL certificate files for the panel.
func updateCert(publicKey string, privateKey string) {
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println(err)
		return
	}

	if (privateKey != "" && publicKey != "") || (privateKey == "" && publicKey == "") {
		settingService := service.SettingService{}
		err = settingService.SetCertFile(publicKey)
		if err != nil {
			fmt.Println("设置证书公钥失败:", err)
		} else {
			fmt.Println("设置证书公钥成功")
		}

		err = settingService.SetKeyFile(privateKey)
		if err != nil {
			fmt.Println("设置证书私钥失败:", err)
		} else {
			fmt.Println("设置证书私钥成功")
		}

		err = settingService.SetSubCertFile(publicKey)
		if err != nil {
			fmt.Println("设置订阅证书公钥失败:", err)
		} else {
			fmt.Println("设置订阅证书公钥成功")
		}

		err = settingService.SetSubKeyFile(privateKey)
		if err != nil {
			fmt.Println("设置订阅证书私钥失败:", err)
		} else {
			fmt.Println("设置订阅证书私钥成功")
		}
	} else {
		fmt.Println("证书公钥和私钥必须同时输入。")
	}
}

// GetCertificate displays the current SSL certificate settings if getCert is true.
func GetCertificate(getCert bool) {
	if getCert {
		settingService := service.SettingService{}
		certFile, err := settingService.GetCertFile()
		if err != nil {
			fmt.Println("get cert file failed, error info:", err)
		}
		keyFile, err := settingService.GetKeyFile()
		if err != nil {
			fmt.Println("get key file failed, error info:", err)
		}

		fmt.Println("cert:", certFile)
		fmt.Println("key:", keyFile)
	}
}

// GetListenIP displays the current panel listen IP address if getListen is true.
func GetListenIP(getListen bool) {
	if getListen {

		settingService := service.SettingService{}
		ListenIP, err := settingService.GetListen()
		if err != nil {
			log.Printf("Failed to retrieve listen IP: %v", err)
			return
		}

		fmt.Println("listenIP:", ListenIP)
	}
}

func GetApiToken(getApiToken bool) {
	if !getApiToken {
		return
	}
	apiTokenService := service.ApiTokenService{}
	tokens, err := apiTokenService.List()
	if err != nil {
		fmt.Println("get apiToken failed, error info:", err)
		return
	}
	if len(tokens) > 0 {
		fmt.Println("apiToken:", tokens[0].Token)
		return
	}
	created, err := apiTokenService.Create("install")
	if err != nil {
		fmt.Println("create apiToken failed, error info:", err)
		return
	}
	fmt.Println("apiToken:", created.Token)
}

// migrateDb performs database migration operations for the 3x-ui panel.
func migrateDb() {
	inboundService := service.InboundService{}

	err := database.InitDB(config.GetDBPath())
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("开始迁移数据库...")
	inboundService.MigrateDB()
	fmt.Println("数据库迁移完成！")
}

// loadServiceEnvFile loads the systemd EnvironmentFile so CLI subcommands like
// "x-ui setting" hit the same database backend as the panel. godotenv.Load does
// not override variables already in the environment, so it is a no-op for the
// systemd-managed service.
func loadServiceEnvFile() {
	for _, path := range config.GetEnvFilePaths() {
		if _, err := os.Stat(path); err != nil {
			continue
		}
		if err := godotenv.Load(path); err != nil {
			log.Printf("warning: failed to load env file %s: %v", path, err)
		}
		return
	}
}

// main is the entry point of the 3x-ui application.
// It parses command-line arguments to run the web server, migrate database, or update settings.
func main() {
	loadServiceEnvFile()

	if len(os.Args) < 2 {
		runWebServer()
		return
	}

	var showVersion bool
	flag.BoolVar(&showVersion, "v", false, "显示版本号")

	runCmd := flag.NewFlagSet("run", flag.ExitOnError)

	migrateDbCmd := flag.NewFlagSet("migrate-db", flag.ExitOnError)
	var migrateDsn string
	var migrateSrc string
	migrateDbCmd.StringVar(&migrateDsn, "dsn", "", "目标 PostgreSQL DSN 连接串 (postgres://user:pass@host:port/db?sslmode=disable)")
	migrateDbCmd.StringVar(&migrateSrc, "src", "", "源 SQLite 数据库文件 (默认使用配置的 x-ui.db)")

	settingCmd := flag.NewFlagSet("setting", flag.ExitOnError)
	var port int
	var username string
	var password string
	var webBasePath string
	var listenIP string
	var getListen bool
	var webCertFile string
	var webKeyFile string
	var tgbottoken string
	var tgbotchatid string
	var enabletgbot bool
	var tgbotRuntime string
	var reset bool
	var show bool
	var getCert bool
	var getApiToken bool
	var resetTwoFactor bool
	settingCmd.BoolVar(&reset, "reset", false, "重置所有面板设置")
	settingCmd.BoolVar(&show, "show", false, "显示当前面板设置")
	settingCmd.IntVar(&port, "port", 0, "设置面板监听端口号")
	settingCmd.StringVar(&username, "username", "", "设置登录用户名")
	settingCmd.StringVar(&password, "password", "", "设置登录密码")
	settingCmd.StringVar(&webBasePath, "webBasePath", "", "设置面板访问根路径 (webBasePath)")
	settingCmd.StringVar(&listenIP, "listenIP", "", "设置面板监听 IP")
	settingCmd.BoolVar(&resetTwoFactor, "resetTwoFactor", false, "重置两步验证设置")
	settingCmd.BoolVar(&getListen, "getListen", false, "显示当前面板监听 IP")
	settingCmd.BoolVar(&getCert, "getCert", false, "显示当前证书配置")
	settingCmd.BoolVar(&getApiToken, "getApiToken", false, "显示当前 API 令牌")
	settingCmd.StringVar(&webCertFile, "webCert", "", "设置面板证书公钥文件路径")
	settingCmd.StringVar(&webKeyFile, "webCertKey", "", "设置面板证书私钥文件路径")
	settingCmd.StringVar(&tgbottoken, "tgbottoken", "", "设置 Telegram 机器人 Token")
	settingCmd.StringVar(&tgbotRuntime, "tgbotRuntime", "", "设置 Telegram 机器人通知定时规则 (Cron)")
	settingCmd.StringVar(&tgbotchatid, "tgbotchatid", "", "设置 Telegram 机器人通知目标 Chat ID")
	settingCmd.BoolVar(&enabletgbot, "enabletgbot", false, "启用 Telegram 机器人通知")

	oldUsage := flag.Usage
	flag.Usage = func() {
		oldUsage()
		fmt.Println()
		fmt.Println("可用命令:")
		fmt.Println("    run            运行 Web 面板服务")
		fmt.Println("    migrate        从旧版或其他 x-ui 迁移数据")
		fmt.Println("    migrate-db     将 SQLite 数据库迁移至 PostgreSQL 数据库")
		fmt.Println("    setting        查看或修改面板配置")
	}

	flag.Parse()
	if showVersion {
		fmt.Println(config.GetVersion())
		return
	}

	switch os.Args[1] {
	case "run":
		err := runCmd.Parse(os.Args[2:])
		if err != nil {
			fmt.Println(err)
			return
		}
		runWebServer()
	case "migrate":
		migrateDb()
	case "migrate-db":
		if err := migrateDbCmd.Parse(os.Args[2:]); err != nil {
			fmt.Println(err)
			return
		}
		src := migrateSrc
		if src == "" {
			src = config.GetDBPath()
		}
		if migrateDsn == "" {
			fmt.Println("--dsn is required: postgres://user:pass@host:port/dbname?sslmode=disable")
			return
		}
		if err := database.MigrateData(src, migrateDsn); err != nil {
			fmt.Println("migration failed:", err)
			os.Exit(1)
		}
	case "setting":
		err := settingCmd.Parse(os.Args[2:])
		if err != nil {
			fmt.Println(err)
			return
		}
		if reset {
			if err = resetSetting(); err != nil {
				return
			}
		} else {
			if err = updateSetting(port, username, password, webBasePath, listenIP, resetTwoFactor); err != nil {
				return
			}
		}
		if show {
			showSetting(show)
		}
		if getListen {
			GetListenIP(getListen)
		}
		if getCert {
			GetCertificate(getCert)
		}
		if getApiToken {
			GetApiToken(getApiToken)
		}
		if (tgbottoken != "") || (tgbotchatid != "") || (tgbotRuntime != "") {
			updateTgbotSetting(tgbottoken, tgbotchatid, tgbotRuntime)
		}
		if enabletgbot {
			updateTgbotEnableSts(enabletgbot)
		}
	case "cert":
		err := settingCmd.Parse(os.Args[2:])
		if err != nil {
			fmt.Println(err)
			return
		}
		if reset {
			updateCert("", "")
		} else {
			updateCert(webCertFile, webKeyFile)
		}
	default:
		fmt.Println("无效的子命令")
		fmt.Println()
		runCmd.Usage()
		fmt.Println()
		settingCmd.Usage()
	}
}
