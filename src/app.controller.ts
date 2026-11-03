import { Controller, Get, Header } from '@nestjs/common';
import { AppService } from './app.service';

@Controller()
export class AppController {
  constructor(private readonly appService: AppService) {}

  // Open this in the browser to see which version is live
  @Get()
  @Header('Content-Type', 'text/html')
  home(): string {
    return `<h1>This is version ${this.appService.getVersion()}</h1>`;
  }

  // Health check used by the deploy script and by you
  @Get('health')
  health() {
    return { status: 'ok', version: this.appService.getVersion() };
  }

  @Get('api/version')
  version() {
    return this.appService.getInfo();
  }

  @Get('api/products')
  products() {
    return this.appService.getProducts();
  }

  @Get('api/users')
  users() {
    return this.appService.getUsers();
  }
}
